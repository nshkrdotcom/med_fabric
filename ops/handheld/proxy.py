"""Transparent TLS fault proxy. Creating the local outage file cuts active and new connections."""
import asyncio
import pathlib
import sys

async def main():
    listen, target = map(int, sys.argv[1:3])
    outage = pathlib.Path(sys.argv[3])
    async def client(reader, writer):
        upstream = None
        tasks = []
        async def copy(src, dst):
            while data := await src.read(65536):
                dst.write(data)
                await dst.drain()
        async def watch():
            while not outage.exists():
                await asyncio.sleep(.025)
        try:
            if outage.exists():
                return
            src, upstream = await asyncio.open_connection("127.0.0.1", target)
            tasks = [asyncio.create_task(c) for c in
                     [copy(reader, upstream), copy(src, writer), watch()]]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (ConnectionError, OSError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            if upstream:
                upstream.close()
    server = await asyncio.start_server(client,"127.0.0.1",listen)
    async with server:
        await server.serve_forever()
if __name__ == "__main__":
    asyncio.run(main())
