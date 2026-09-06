# Standard-library integration runner for the production HTTPServer/parser/file transport.
# Uses an ephemeral loopback-only listener and synthetic files, never the live app.
# Run: python3 Tests/ClipxCoreTests/ServerHTTPRegression.py
SWIFT_FIXTURE = r'''
import Foundation
@main struct Main {
 @MainActor static func main() async throws {
  let server = HTTPServer(port: 0, bindToLoopback: true)
  let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let size = Int64((try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! NSNumber).int64Value)
  try server.start { request in
   if request.path == "/slow" {
    do { try await Task.sleep(nanoseconds: 10_000_000_000); return .plain("late") }
    catch { print("CANCELLED_HANDLER"); fflush(stdout); return .plain("cancelled",status:503) }
   }
   if request.path == "/stop" {
    Task { @MainActor in try? await Task.sleep(nanoseconds: 100_000_000); server.stop() }
    return .plain("stopping")
   }
   guard request.path == "/file" else { return .plain("paired route",status:401) }
   guard let range = resolveByteRange(request.headers["range"],size:size,maxChunk:.max) else { return HTTPResponse(status:416,headers:["Content-Range":"bytes */\(size)"]) }
   var response = HTTPResponse(status:request.headers["range"] == nil ? 200:206,headers:["Content-Type":"application/octet-stream"])
   if request.headers["range"] != nil { response.headers["Content-Range"]="bytes \(range.start)-\(range.end)/\(size)" }
   response.fileBody = try? HTTPResponse.FileBody(url:fileURL,offset:range.start,length:range.end-range.start+1)
   return response
  }
  while server.listeningPort == nil || server.listeningPort == 0 { try await Task.sleep(nanoseconds:10_000_000) }
  print("PORT=\(server.listeningPort!)"); fflush(stdout)
  while server.isRunning { try await Task.sleep(nanoseconds:10_000_000) }
  try await Task.sleep(nanoseconds:100_000_000)
 }
}
'''
import pathlib,tempfile,subprocess,socket,time,select
root=pathlib.Path(tempfile.mkdtemp(prefix='clipx-http-regression-'))
project=pathlib.Path(__file__).resolve().parents[2]
main=root/'main.swift'
main.write_text(SWIFT_FIXTURE)
logger=root/'logger.swift'
logger.write_text('import OSLog\nenum ClipxLog { static let app = Logger(subsystem: "clipx.http.regression", category: "server") }\n')
binary=root/'server'
subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(root/'module-cache'),
 *[str(project/'Sources/ClipxServer'/name) for name in ['HTTPRequest.swift','HTTPResponse.swift','HTTPServer.swift','Security.swift']],
 str(logger),str(main),'-o',str(binary)],check=True)
fixture=bytes(i%251 for i in range(2_500_000)); file=root/'fixture.bin';file.write_bytes(fixture)
process=subprocess.Popen([str(binary),str(file)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
try:
 ready=select.select([process.stdout],[],[],10)[0]
 assert ready,'server did not become ready'
 line=process.stdout.readline(); assert line.startswith('PORT='),line
 port=int(line.split('=')[1])
 def connect(): return socket.create_connection(('127.0.0.1',port),timeout=5)
 def send(wire):
  with connect() as sock:
   sock.sendall(wire);data=b''
   while chunk:=sock.recv(65536): data+=chunk
   head,body=data.split(b'\r\n\r\n',1)
   return head,body
 for wire in [b'GET /?= HTTP/1.1\r\nHost: localhost\r\n\r\n',b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n']:
  head,body=send(wire);assert b'400 Bad Request' in head,head
 head,body=send(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');assert b'401 Unauthorized' in head
 for raw_range,expected in [(None,fixture),('bytes=-500',fixture[-500:]),('bytes=10-2000000',fixture[10:2000001])]:
  suffix=('Range: '+raw_range+'\r\n').encode() if raw_range else b''
  head,body=send(b'GET /file HTTP/1.1\r\nHost: localhost\r\n'+suffix+b'\r\n')
  assert body==expected,(len(body),len(expected))
  assert (b'206 Partial Content' if raw_range else b'200 OK') in head,head
 slow=connect();slow.sendall(b'GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n');time.sleep(.1)
 send(b'GET /stop HTTP/1.1\r\nHost: localhost\r\n\r\n')
 assert slow.recv(1024)==b'', 'stopping must close accepted connections';slow.close()
 output=process.communicate(timeout=5)[0];assert 'CANCELLED_HANDLER' in output,output
 print('PASS: actual loopback HTTP parser rejection, subsequent auth response, full/suffix/large explicit streaming, server shutdown connection and handler cancellation')
finally:
 if process.poll() is None: process.terminate();process.wait(timeout=5)
