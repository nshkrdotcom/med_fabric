"""Separate-process synthetic reference lab. Run using the Elixir entry points in ops/."""
import argparse
import contextlib
import hashlib
import http.cookiejar
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
from fractions import Fraction
from html.parser import HTMLParser

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAIRED, PLX = "paired_exam", "plx_spot_check"
def sha(b):
    return hashlib.sha256(b).hexdigest()
def save(path, obj):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2) + "\n")
    tmp.chmod(0o600)
    tmp.replace(path)
def read(path):
    return json.loads(path.read_text())
def ports(n):
    with contextlib.ExitStack() as stack:
        socks = [stack.enter_context(socket.socket()) for _ in range(n)]
        for s in socks:
            s.bind(("127.0.0.1", 0))
        return [s.getsockname()[1] for s in socks]
def prepare(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if list(directory.iterdir()):
        raise ValueError("choose a new empty run directory")
    directory.chmod(0o700)
    h,t,p,pg,pv,fhir = ports(6)
    names = ["artifact","spool","barriers","oracle","logs","pghost"]
    for name in names:
        (directory/name).mkdir(mode=0o700)
    for name in ["device.credential","preview.credential","postgres.credential"]:
        file = directory/name
        file.write_text(secrets.token_urlsafe(48))
        file.chmod(0o600)
    crt, key = directory/"cert.pem", directory/"key.pem"
    subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","2",
                    "-subj","/CN=localhost","-addext","subjectAltName=DNS:localhost,IP:127.0.0.1",
                    "-addext","basicConstraints=critical,CA:TRUE","-keyout",str(key),"-out",str(crt)],
                   check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    tag = secrets.token_hex(6)
    encounter = {"exam":"fixture-"+tag,"patient_actor":"synthetic-patient","clinician_actor":"synthetic-reviewer",
                 "patient_key":secrets.token_urlsafe(40),"clinician_key":secrets.token_urlsafe(40),
                 "patient_ref":"Patient/fixture-"+tag,"encounter_ref":"Encounter/fixture-"+tag,
                 "destination":f"http://127.0.0.1:{fhir}/fhir"}
    cfg = {"http_port":h,"tls_port":t,"proxy_port":p,"postgres_port":pg,"preview_port":pv,
           "database_url":f"postgres://lab:{(directory / 'postgres.credential').read_text()}@127.0.0.1:{pg}/postgres","cookie_secret":secrets.token_urlsafe(64),
           "artifact_dir":str(directory/"artifact"), "barrier_dir":str(directory/"barriers"),
           "cert":str(crt),"key":str(key),"encounters":[encounter],"preview_url":None,
           "preview_credential_file":str(directory/"preview.credential"),"authorize_scenarios":True,
           "devices":[{"id":"reference-gateway","credential_file":str(directory/"device.credential"),"exam":encounter["exam"]}]}
    secondary=dict(encounter,exam="secondary-"+tag,patient_key=secrets.token_urlsafe(40),clinician_key=secrets.token_urlsafe(40),
                   patient_ref="Patient/secondary-"+tag,encounter_ref="Encounter/secondary-"+tag)
    secondary_token=directory/"secondary.credential"
    secondary_token.write_text(secrets.token_urlsafe(48));secondary_token.chmod(0o600)
    cfg["encounters"].append(secondary)
    cfg["devices"].append({"id":"secondary-gateway","exam":secondary["exam"],"credential_file":str(secondary_token)})
    client={"server":f"wss://localhost:{p}","ca_file":str(crt),"credential_file":str(directory/"device.credential"),
            "device":"reference-gateway","encounter":encounter["exam"],"acquisition":"paired-"+tag,
            "seed":37,"seconds":60,"spool_root":str(directory/"spool"),"spool_limit":67108864,"preview":False}
    save(directory/"server.json",cfg)
    save(directory/"handheld-a.json",client)
    return cfg,client

class CSRF(HTMLParser):
    def __init__(self):
        super().__init__()
        self.token = None
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=="meta" and a.get("name")=="csrf-token":
            self.token=a["content"]

class Lab:
    def __init__(self, args, directory):
        self.a,self.dir=args,directory
        self.cfg,self.client=prepare(directory)
        self.required = ["paired","spot-check","legacy-browser"] if args.suite=="all" else [args.suite]
        self.report={"schema":"medfabric.acceptance.v1","passed":False,"required_suites":self.required,
                     "skipped_required":list(self.required),"seed":self.client["seed"],"scenarios":{},
                     "processes":[],"service_versions":{},"configured_limits":{"pending_frames":16,"pending_bytes":262144,"spool_bytes":67108864,"frame_bytes":65536,"metadata_records":100000},
                     "measured_maxima":{},"source_identities":{},"review_revisions":[],"fhir_external_ids":[],
                     "raw_payload_digests":{},"oracle_payload_digests":{},"clock_holdout_violations":None,
                     "unknown_command_outcome_exercised":False,"preview_os_process_killed":False,"bounds_respected":False}
        self.started=time.monotonic(); self.procs=[]; self.seq=0; self.server=None; self.preview=None
        self.env=dict(os.environ,PGHOST="127.0.0.1",PGPORT=str(self.cfg["postgres_port"]),PGUSER="lab",PGDATABASE="postgres",PGPASSWORD=(directory/"postgres.credential").read_text())
        self.browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.container=None
    def isolate(self,role,args,config=None):
        # Retain installed libraries and local Mix dependency contexts. A separate
        # mount namespace hides the entire run tree, then exposes only role inputs.
        base=["bwrap","--die-with-parent","--unshare-pid","--ro-bind","/","/","--dev-bind","/dev","/dev","--proc","/proc",
              "--bind",str(ROOT/"apps"/role),str(ROOT/"apps"/role),"--tmpfs",str(self.dir),
              "--dir",str(self.dir/"runtime-tmp"),"--tmpfs",str(self.dir/"runtime-tmp"),"--setenv","TMPDIR",str(self.dir/"runtime-tmp")]
        if role=="exam":
            files=["server.json","cert.pem","key.pem","device.credential","secondary.credential","preview.credential"]
            dirs=["artifact","barriers"]
        elif role=="preview":
            files=["preview.credential"];dirs=[]
        else:
            files=[str(pathlib.Path(config).relative_to(self.dir)),"cert.pem",pathlib.Path(read(pathlib.Path(config))["credential_file"]).name]
            cfg=read(pathlib.Path(config))
            spool="spool/"+cfg["acquisition"]
            (self.dir/spool).mkdir(exist_ok=True,parents=True)
            dirs=[spool]
        for n in dirs:
            path=str(self.dir/n);base+=["--dir",path,"--bind",path,path]
        for n in files:
            path=str(self.dir/n);base+=["--ro-bind",path,path]
        return base+["--"]+list(map(str,args))
    def launch(self,name,args,cwd=ROOT,env=None):
        self.seq+=1
        env=dict(env or self.env)
        if cwd==ROOT/"apps/handheld":
            path=args[-1] if name=="network-denials" else args[args.index("--config")+1]
            args=self.isolate("handheld",args,path)
            for key in list(env):
                if key.startswith(("PG","MF_","DATABASE_","FHIR_")): env.pop(key)
        elif name=="preview":
            args=self.isolate("preview",args)
            env={k:v for k,v in env.items() if not k.startswith(("PG","DATABASE_","FHIR_"))}
        elif name=="exam":
            args=self.isolate("exam",args)
        path=self.dir/"logs"/f"{self.seq:03d}-{name}.log"
        with path.open("wb") as log:
            p=subprocess.Popen(list(map(str,args)),cwd=cwd,env=env or self.env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,stdin=subprocess.DEVNULL)
        item={"name":name,"pid":p.pid,"exit":None,"log":str(path.relative_to(self.dir))}
        self.report["processes"].append(item);self.procs.append((p,item))
        return p
    def stop(self,p,kill=False):
        if p and p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL if kill else signal.SIGTERM)
            try: p.wait(8)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL);p.wait(2)
    def wait(self,fn,timeout=30,p=None):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            if p and p.poll() is not None: raise RuntimeError("subprocess exited before readiness; see retained logs")
            try:
                value=fn()
                if value: return value
            except (OSError,urllib.error.URLError,subprocess.CalledProcessError):
                pass
            time.sleep(.05)
        raise TimeoutError("readiness or evidence deadline expired")
    def run(self,name,args,cwd=ROOT,timeout=180,env=None):
        p=self.launch(name,args,cwd,env)
        code=p.wait(timeout)
        if code: raise RuntimeError(f"{name} exited {code}")
    def sql(self,sql):
        return subprocess.check_output(["psql","-XAt","-v","ON_ERROR_STOP=1","-c",sql],env=self.env,text=True,stderr=subprocess.DEVNULL,timeout=6).strip()
    def get(self,url,timeout=3):
        with self.browser.open(url,timeout=timeout) as r:return r.read()
    def health(self,port):
        with socket.create_connection(("127.0.0.1",port),timeout=.3):return True
    def init(self):
        for binary in ["mix","elixir","initdb","postgres","psql","openssl","flock","bwrap"]:
            if not shutil.which(binary): raise RuntimeError(f"Missing prerequisite {binary}")
        for repo in ["med_ex","med_fabric","weld"]:
            path=ROOT.parent/repo
            if (path/".git").exists():
                rev=subprocess.check_output(["git","rev-parse","HEAD"],cwd=path,text=True).strip()
                dirty=bool(subprocess.check_output(["git","status","--porcelain"],cwd=path))
                self.report["source_identities"][repo]={"head":rev,"dirty":dirty}
        for name,args in {"elixir":["elixir","--version"],"postgres":["postgres","--version"]}.items():
            self.report["service_versions"][name]=subprocess.check_output(args,text=True).strip()
        selection=ROOT/".mix_sources.json"
        self.report["dependency_source_selections"]=read(selection) if selection.exists() else {}
        # Record exact content-identifying lock and source-file hashes.
        self.report["dependency_lock_sha256"]={str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in ROOT.glob("**/mix.lock") if "deps" not in p.parts}
        self.run("initdb",["initdb","-D",self.dir/"pgdata","-U","lab","--auth-local=trust","--auth-host=scram-sha-256","--pwfile",self.dir/"postgres.credential","--no-locale"])
        pg=self.launch("postgres",["postgres","-D",self.dir/"pgdata","-k",self.dir/"pghost","-h","127.0.0.1","-p",self.cfg["postgres_port"]])
        self.wait(lambda:self.sql("SELECT 1")=="1",p=pg)
        if "spot-check" in self.required:
            if self.a.fhir!="hapi":raise ValueError("--fhir hapi is required")
            self.hapi()
        if self.a.preview=="isolated": self.start_preview()
        save(self.dir/"server.json",self.cfg)
        self.start_server()
        proxy=self.launch("tls-proxy",[sys.executable,ROOT/"ops/handheld/proxy.py",self.cfg["proxy_port"],self.cfg["tls_port"],self.dir/"outage"])
        self.wait(lambda:self.health(self.cfg["proxy_port"]),p=proxy)
        self.login()
    def hapi(self):
        external=os.environ.get("FHIR_BASE_URL")
        e=self.cfg["encounters"][0]
        if external:
            e["destination"]=external.rstrip("/")
        else:
            self.container="fabric-hapi-"+secrets.token_hex(6)
            port=e["destination"].split(":")[-1].split("/")[0]
            self.launch("hapi",["docker","run","--rm","--name",self.container,"-p",f"127.0.0.1:{port}:8080",os.getenv("MF_HAPI_IMAGE","hapiproject/hapi:v7.6.1")])
        base=e["destination"]
        cap=self.wait(lambda:json.loads(self.get(base+"/metadata")),timeout=120)
        if not cap["fhirVersion"].startswith("4.0"):raise ValueError("FHIR R4 required")
        self.report["service_versions"]["hapi"]=cap.get("software",{})
        for typ,ident,extra in [("Patient",e["patient_ref"].split("/")[1],{}),("Encounter",e["encounter_ref"].split("/")[1],{"status":"in-progress","class":{"system":"http://terminology.hl7.org/CodeSystem/v3-ActCode","code":"AMB"},"subject":{"reference":e["patient_ref"]}}),("Device","synthetic-plx",{"status":"active","deviceName":[{"name":"Synthetic PLXS fixture","type":"user-friendly-name"}]})]:
            resource={"resourceType":typ,"id":ident,**extra}
            req=urllib.request.Request(f"{base}/{typ}/{ident}",method="PUT",data=json.dumps(resource).encode(),headers={"Content-Type":"application/fhir+json","If-None-Match":"*"})
            try:
                with urllib.request.urlopen(req) as r:r.read()
            except urllib.error.HTTPError as err:
                if typ!="Device" or err.code!=412:raise
                existing=json.loads(self.get(f"{base}/{typ}/{ident}"))
                if existing.get("deviceName")!=extra["deviceName"]:raise ValueError("foreign fixture Device")
    def start_preview(self):
        self.cfg["preview_url"]="http://127.0.0.1:"+str(self.cfg["preview_port"])
        self.preview=self.launch("preview",["mix","run","--no-halt"],ROOT/"apps/preview",dict(self.env,MF_PREVIEW_CREDENTIAL_FILE=self.cfg["preview_credential_file"],MF_PREVIEW_PORT=str(self.cfg["preview_port"])))
        self.wait(lambda:self.health(self.cfg["preview_port"]),p=self.preview)
    def start_server(self):
        self.server=self.launch("exam",["mix","run","--no-start","--no-halt",ROOT/"ops/run_exam.exs","--config",self.dir/"server.json"],ROOT/"apps/exam")
        path=self.dir/self.procs[-1][1]["log"]
        self.wait(lambda:"Synthetic exam ready" in path.read_text(errors="replace"),p=self.server)
    def login(self):
        e=self.cfg["encounters"][0]
        self.base=f'http://localhost:{self.cfg["http_port"]}/encounters/{e["exam"]}'
        parser=CSRF();parser.feed(self.get(self.base+"?key="+e["clinician_key"]).decode())
        if not parser.token:raise RuntimeError("clinician session has no CSRF token")
        self.csrf=parser.token
    def action(self,id,action,expect=200,**args):
        req=urllib.request.Request(f"{self.base}/devices/{id}/action",data=json.dumps(dict(args,action=action)).encode(),headers={"content-type":"application/json","x-csrf-token":self.csrf})
        try:
            with self.browser.open(req) as r:status=r.status
        except urllib.error.HTTPError as e:status=e.code
        assert status==expect,(action,status,expect)
    def client_process(self,profile,case,**changes):
        cfg=dict(self.client,acquisition=case+"-"+secrets.token_hex(5),preview=self.a.preview=="isolated",**changes)
        path=self.dir/(cfg["acquisition"]+".json");save(path,cfg)
        return cfg,self.launch(case,["mix","run","-e","MedExHandheld.CLI.main(System.argv())","--","--config",path,"--scenario",profile],ROOT/"apps/handheld")
    def manifest(self,cfg):
        path=self.dir/"artifact"/"device-v1"/sha(cfg["acquisition"].encode())/"manifest.mej1"
        blob=path.read_bytes()
        digest=sha(blob)
        assert self.sql(f"SELECT digest FROM device_manifests WHERE acquisition_id='{cfg['acquisition']}'")==digest
        m=json.loads(blob)
        return path.parent,digest,m
    def oracle(self,cfg,root,m):
        actual,expected,intervals,coverage={}, {}, {}, {}
        duplicates=0
        for name,s in m["streams"].items():
            idx=s["index"]; src=1 if name=="audio" else 2
            desc=idx["stream"];width={"s16le":2,"s24le":3,"s32le":4}[desc["encoding"]]
            chans=len(desc["channels"]); rawhash,oracle=hashlib.sha256(),hashlib.sha256()
            ranges=[];spans=[]
            for seg in idx["segments"]:
                first,end=map(int,[seg["first_sample"],seg["end_sample"]])
                binary=(root/name/idx["fence"]/seg["key"]).read_bytes()
                assert sha(binary)==seg["sha256"] and len(binary)==(end-first)*chans*width
                rawhash.update(binary)
                ranges.append((first,end));spans.append((first,end,"data"))
            gaps=[(int(x["first_sample"]),int(x["end_sample"])) for x in idx["spans"] if x["code"]=="source_gap"]
            spans+= [(a,b,"gap") for a,b in gaps]
            edge=0
            for a,b,kind in sorted(spans):
                if a<edge:duplicates+=1
                assert a==edge
                edge=b
            num,den=map(int,desc["sample_rate"])
            if not cfg.get("spool_limit",67108864)<67108864 and not cfg.get("reset"):
                assert edge==cfg["seconds"]*num//den,(edge,cfg["seconds"]*num//den)
            expected_gap=[(1920,2020)] if cfg.get("gap") and name=="audio" else []
            assert gaps==expected_gap
            for i in range(edge):
                if any(a<=i<b for a,b in expected_gap):continue
                for ch in range(1,chans+1):
                    v=(i*37+cfg["seed"]*17+ch*13+src*101)%65536-32768
                    oracle.update(v.to_bytes(width,"little",signed=True))
            expected[name]=oracle.hexdigest();actual[name]=rawhash.hexdigest()
            assert expected[name]==actual[name],(name,expected[name],actual[name])
            intervals[name]={"spans":ranges,"gaps":gaps,"samples":edge,"index_digest":s["digest"]}
            coverage[name]=self.clock_check(cfg,s,name,edge,num,den)
        return {"raw_payload_digests":actual,"oracle_payload_digests":expected,
                "coverage":intervals,"clock_holdouts":coverage,"duplicate_logical_frames":duplicates}
    def clock_check(self,cfg,s,name,edge,num,den):
        clock=s["clock"]
        if clock["state"]!="bounded" or edge==0:return {"state":"unavailable","tested":0,"violations":0}
        ident=read(self.dir/"spool"/cfg["acquisition"]/"identity.json")
        m=clock["wall_mapping"];fit=clock["estimate"]
        def frac(v):
            return Fraction(*map(int,v)) if isinstance(v,list) else Fraction(int(v))
        verts=[tuple(map(frac,v)) for v in fit["vertices"]]
        observed=list(map(frac,fit["probe_span_us"]))
        failures=[]
        for i in sorted(set([0,edge//3,edge//2,edge-1])):
            device=Fraction(180000)+Fraction(i*1000000*den,num)
            a,b=device-2,device+2
            error=max(0,observed[0]-a,b-observed[1])*frac(fit["holdover_rate"])
            lo=min(k*a+t for k,t in verts)-error
            hi=max(k*b+t for k,t in verts)+error
            ground=ident["origin_us"]+int((device-180000)*Fraction(1000000+(35 if name=="audio" else -40),1000000))
            lower=ground+int(m["host_monotonic_us"])-int(m["wall_after_us"])
            upper=ground+int(m["host_monotonic_us"])-int(m["wall_before_us"])
            if lo.__floor__()>lower or hi.__ceil__()<upper:failures.append(i)
        return {"state":"bounded","tested":len(set([0,edge//3,edge//2,edge-1])),"violations":len(failures),"failed_samples":failures}
    def command_and_stall(self,cfg,barrier,child):
        id=cfg["acquisition"]
        def count(table,where):
            return int(self.sql(f"SELECT count(*) FROM {table} WHERE {where}"))
        self.wait(lambda: count("stream_attempts",f"acquisition_id='{id}'")==2,p=child)
        if self.preview:
            viewer=self.launch("rtc-viewer",["node",ROOT/"ops/handheld/monitor_viewer.mjs",self.dir/"server.json",id,self.dir/"viewer.ready"])
            self.wait((self.dir/"viewer.ready").exists,p=viewer)
        self.action(id,"monitor_gain",gain="half")
        self.wait(lambda: count("device_facts",f"acquisition_id='{id}' AND kind='command_outcome_unknown'")>0,p=child)
        barrier.touch()
        reached=barrier.with_suffix(".reached")
        self.wait(reached.exists,p=child)
        def counters():
            audio=int(self.sql(f"SELECT coalesce(sum(durable_acks),0) FROM device_limits_observed l JOIN stream_attempts a USING(fence) WHERE a.acquisition_id='{id}' AND stream='audio'"))
            beats=int(self.sql(f"SELECT count FROM device_heartbeats WHERE acquisition_id='{id}'"))
            return audio,beats
        old=counters()
        time.sleep(5)
        new=counters()
        reached.unlink()
        self.report["sibling_stall_audio_receipts"]=new[0]-old[0]
        self.report["sibling_stall_heartbeats"]=new[1]-old[1]
        assert all(b>a for a,b in zip(old,new))
    def paired_case(self,case,barrier=None,**settings):
        armed=self.dir/"barriers"/(barrier+".armed") if barrier else None
        if armed:armed.touch()
        cfg,p=self.client_process(PAIRED,case,**settings)
        if case=="baseline":
            self.command_and_stall(cfg,self.dir/"barriers/writer_stall.ecg.armed",p)
            if self.preview:
                self.stop(self.preview,kill=True)
                assert self.preview.returncode==-signal.SIGKILL
                self.report["preview_os_process_killed"]=True
                self.start_preview()
            outage=self.dir/"outage"
            outage.touch();time.sleep(10);outage.unlink()
        if armed:
            reached=armed.with_suffix(".reached")
            self.wait(reached.exists,p=p)
            self.stop(self.server,kill=True)
            reached.unlink()
            self.start_server();self.login()
        code=p.wait(180)
        assert code==0,(case,code)
        root,digest,m=self.manifest(cfg)
        res=self.oracle(cfg,root,m)
        res.update(manifest_digest=digest,manifest_path=str(root.relative_to(self.dir)/"manifest.mej1"))
        if case=="baseline":
            for k in ["raw_payload_digests","oracle_payload_digests","duplicate_logical_frames"]:self.report[k]=res[k]
            checks=res["clock_holdouts"]
            assert all(x["tested"]>0 for x in checks.values())
            self.report["clock_holdout_violations"]=sum(x["violations"] for x in checks.values())
            assert self.report["clock_holdout_violations"]==0
            self.report["unknown_command_outcome_exercised"]=any(f["type"]=="command_outcome_unknown" for f in m["facts"])
            monitor=read(self.dir/"spool"/cfg["acquisition"]/"monitor.json")
            assert self.report["unknown_command_outcome_exercised"] and monitor["epoch"]=="1" and monitor["gain"]=="half"
            self.report["command_mutations"]=len(monitor["cache"])
            changed=int(next(iter(monitor["cache"].values()))["first_sample"])
            tested=0
            for line in (self.dir/"spool"/cfg["acquisition"]/"monitor-truth.jsonl").read_text().splitlines():
                record=json.loads(line); first=record["first"]; count=record["count"]
                divisor=2 if first>=changed else 1
                values=[(i*37+cfg["seed"]*17+13+101)%65536-32768 for i in range(first,first+count)]
                pcm=b"".join(int(v/divisor).to_bytes(2,"little",signed=True) for v in values)
                assert record["sha256"]==sha(pcm)
                tested+=count
            assert tested==cfg["seconds"]*48000
            self.report["monitor_checked_samples"]=tested
        decision="partial" if m["defects"] else "complete"
        stream="audio" if m["streams"]["audio"]["index"]["segments"] else "ecg"
        segments=m["streams"][stream]["index"]["segments"]
        if segments:
            seg=segments[0]
            choice={"decision":decision,"note":"Synthetic review","ranges":[{"stream":stream,"first":seg["first_sample"],"end":seg["end_sample"]}],"metrics":[],"acknowledged":m["defects"]}
        else:
            choice={"decision":"reject","note":"No verified samples","metrics":[]}
        self.action(cfg["acquisition"],"review",expect=409,digest="0"*64,choice=choice)
        self.action(cfg["acquisition"],"review",digest=digest,choice=choice)
        self.report["review_revisions"].append(digest)
        self.report["scenarios"][case]=res
        return res
    def paired(self):
        self.paired_case("baseline",seconds=60,lose_command_ack=True,trace_monitor=True)
        self.paired_case("source-gap",seconds=3,gap=True)
        self.paired_case("rational-s24",seconds=3,variant=True)
        for event in ["accepted_before_durable.audio","durable_before_ack.audio","after_object_install.audio","manifest_install.all","db_completion.all"]:
            self.paired_case(event.split(".")[0],event,seconds=4)
        self.paired_case("spool-capacity",seconds=4,spool_limit=1200)
        d=self.cfg["devices"][1]
        cfg=dict(self.client,acquisition="negative-"+secrets.token_hex(5),device=d["id"],encounter=d["exam"],
                 wrong_encounter=self.client["encounter"],credential_file=d["credential_file"],negative_result=None)
        cfg["negative_result"]=str(self.dir/"spool"/cfg["acquisition"]/"network-denials.json")
        save(self.dir/"negative.json",cfg)
        self.run("network-denials",["mix","run","integration/network_denials.exs",self.dir/"negative.json"],ROOT/"apps/handheld")
        assert len(read(pathlib.Path(cfg["negative_result"]))["checked"])==7
        self.sql("UPDATE device_credentials SET revoked=true WHERE device_id='secondary-gateway'")
        self.wait(lambda:self.sql(f"SELECT state FROM acquisitions WHERE id='{cfg['acquisition']}'")=="interrupted")
        self.report["scenarios"]["network-denials"]=read(pathlib.Path(cfg["negative_result"]))
        reset=self.paired_case("source-reset",seconds=4,reset=True)
        assert reset["coverage"]["ecg"]["samples"]==75
        r=self.sql("SELECT max(max_frame_bytes),max(max_pending_bytes),max(max_pending_frames) FROM device_limits_observed").split("|")
        maxima={"frame_bytes":int(r[0]),"pending_bytes":int(r[1]),"pending_frames":int(r[2]),
                "spool_bytes":max(read(p)["spool"]["maximum"] for p in (self.dir/"spool").glob("*/result.json")),
                "metadata_records":int(self.sql("SELECT coalesce(max((receipt->>'journal_generation')::integer),0) FROM stream_attempts"))}
        self.report["measured_maxima"]=maxima
        self.report["bounds_respected"]=all(0<=n<=self.report["configured_limits"][key] for key,n in maxima.items())
        assert self.report["bounds_respected"]
    def spot(self):
        # Produce offline, kill the handheld after local sync, and restart with the same journal.
        outage=self.dir/"outage"
        cfg,p=self.client_process(PLX,"plx",offline_finish=True,hold_after_ingestion=True)
        root=self.dir/"spool"/cfg["acquisition"]
        self.wait(lambda:(root/"inventory.json").exists(),p=p)
        outage.touch()
        self.stop(p,kill=True);outage.unlink()
        barrier=self.dir/"barriers/measurement_commit.all.armed";barrier.touch()
        path=self.dir/(cfg["acquisition"]+".json")
        args=["mix","run","-e","MedExHandheld.CLI.main(System.argv())","--","--config",path,"--scenario",PLX]
        p=self.launch("plx-restart",args,ROOT/"apps/handheld")
        reached=barrier.with_suffix(".reached")
        self.wait(reached.exists,p=p)
        self.stop(self.server,kill=True);reached.unlink()
        self.start_server();self.login()
        assert p.wait(120)==0
        _,digest,m=self.manifest(cfg)
        inv=m["inventory"];assert len(inv)==2
        assert inv[0]["event"]["metrics"]["spo2"]=={"missing":"nan"}
        event=inv[1]["event"]
        assert event["repeat_of"]==inv[0]["event"]["event_id"]
        choice={"decision":"accept_metrics","metrics":["pulse_rate","spo2"],"note":"Synthetic acceptable completed event","event_id":event["event_id"]}
        id=cfg["acquisition"]
        self.action(id,"review",expect=409,digest=digest,choice=dict(choice,event_id=inv[0]["event"]["event_id"]))
        self.action(id,"review",digest=digest,choice=choice)
        self.action(id,"review",digest=digest,choice=choice)
        metrics=self.sql(f"SELECT id FROM acquisitions WHERE parent_acquisition_id='{id}' ORDER BY id").splitlines()
        assert len(metrics)==2
        for metric in metrics:self.action(metric,"deliver")
        remote=self.sql(f"SELECT external_id,remote_ref FROM outbox_deliveries WHERE acquisition_id IN (SELECT id FROM acquisitions WHERE parent_acquisition_id='{id}')").splitlines()
        assert len(remote)==2
        for record in remote:
            external,ref=record.split("|")
            assert ref.startswith("Observation/")
            system="urn:med-fabric:observation|"+external
            url=self.cfg["encounters"][0]["destination"]
            bundle=json.loads(self.get(url+"/Observation?"+urllib.parse.urlencode({"identifier":system})))
            resources=[e["resource"] for e in bundle.get("entry",[]) if e.get("search",{}).get("mode","match")=="match"]
            assert len(resources)==1 and resources[0]["effectiveDateTime"]==event["measured_at"]
            self.report["fhir_external_ids"].append({"external":external,"remote":ref})
        env=dict(self.env,FHIR_BASE_URL=self.cfg["encounters"][0]["destination"])
        self.run("hapi-loss-readback",["mix","test","integration"],ROOT/"core/interop",env=env)
        self.report["review_revisions"].append(digest)
        self.report["scenarios"]["plx"]={"event_ids":[e["event"]["event_id"] for e in inv],"digest":digest}
    def legacy(self):
        # The supplied snapshot contains callback integration tests. An actual browser
        # gate is additionally required and runs against this server using Playwright.
        self.stop(self.server)
        self.env["MF_EXAM_LEGACY_MEDIA"]="1"
        self.start_server();self.login()
        self.run("legacy-capture",["mix","test","integration/recording_test.exs","integration/encounter_scope_test.exs"],ROOT/"apps/exam",env=dict(self.env,DATABASE_URL=self.cfg["database_url"]))
        self.run("legacy-browser",["node",ROOT/"ops/handheld/legacy_browser.mjs",self.dir/"server.json"])
    def execute(self):
        self.init()
        for suite in self.required:
            start=time.monotonic()
            {"paired":self.paired,"spot-check":self.spot,"legacy-browser":self.legacy}[suite]()
            self.report["scenarios"][suite+"-elapsed-seconds"]=round(time.monotonic()-start,3)
            self.report["skipped_required"].remove(suite)
        self.report["passed"]=not self.report["skipped_required"]
    def close(self):
        for p,item in reversed(self.procs):
            self.stop(p)
            item["exit"]=p.poll()
        if self.container:
            subprocess.run(["docker","rm","-f",self.container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        self.report["elapsed_seconds"]=round(time.monotonic()-self.started,3)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("operation",choices=["prepare","acceptance"])
    parser.add_argument("--run-dir",type=pathlib.Path)
    parser.add_argument("--suite",choices=["paired","spot-check","legacy-browser","all"],default="paired")
    parser.add_argument("--preview",choices=["off","isolated"],default="off")
    parser.add_argument("--fhir",choices=["hapi"])
    parser.add_argument("--report",type=pathlib.Path)
    a=parser.parse_args()
    directory=(a.run_dir or pathlib.Path(tempfile.mkdtemp(prefix="med-fabric-"))).resolve()
    if a.operation=="prepare":
        prepare(directory);print(f"Prepared synthetic lab at {directory}");return 0
    lab=Lab(a,directory)
    target=a.report or directory/"report.json"
    def expired(*_):
        raise TimeoutError("suite deadline exceeded")
    signal.signal(signal.SIGALRM,expired)
    signal.alarm({"paired":900,"spot-check":300,"legacy-browser":300,"all":1500}[a.suite])
    try:
        lab.execute()
    except Exception as e:
        lab.report.update(passed=False,error=type(e).__name__+": "+str(e))
    finally:
        signal.alarm(0)
        try:lab.close()
        except Exception as e:lab.report.update(passed=False,cleanup_error=str(e))
        target.parent.mkdir(parents=True,exist_ok=True)
        save(target,lab.report)
    print(f"Acceptance report {target}")
    return 0 if lab.report["passed"] else 1
if __name__=="__main__":
    sys.exit(main())
