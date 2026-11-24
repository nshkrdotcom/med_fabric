{_,code}=System.cmd(System.find_executable("python3") || raise("python3 required"),
  [Path.join(__DIR__,"handheld/acceptance.py"),"acceptance" | System.argv()],into: IO.stream(),stderr_to_stdout: true)
System.halt(code)
