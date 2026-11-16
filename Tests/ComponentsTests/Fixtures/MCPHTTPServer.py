"""Owned loopback fixture. Synthetic MCP frames; no external service/client."""
import http.server,json,os,queue,socket,sys,threading,time
from pathlib import Path
mode,root=sys.argv[1],Path(sys.argv[2])
messages=queue.Queue(maxsize=32)
record_lock=threading.Lock()
last_initialize=None
resume_reply=None

def record(value):
    with record_lock:
        with (root/'wire.jsonl').open('a') as f:f.write(json.dumps(value)+'\n')

def result(message):
    method=message.get('method')
    if method=='initialize':
        return {'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'http-fixture','version':'1'}}
    cursor=message.get('params',{}).get('cursor')
    value={'tools':[{'name':'first' if not cursor else 'second','inputSchema':{'type':'object'}}]}
    if not cursor:value['nextCursor']='next'
    return value

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def log_request_data(self,method):
        record({'http':self.command,'path':self.path,'method':method,
                'authorization':self.headers.get('Authorization') is not None,
                'session':self.headers.get('Mcp-Session-Id'),'version':self.headers.get('MCP-Protocol-Version'),
                'lastEventID':self.headers.get('Last-Event-ID')})
    def empty(self,status,headers={}):
        self.send_response(status)
        for key,value in headers.items():self.send_header(key,value)
        self.send_header('Content-Length','0');self.end_headers()
    def do_POST(self):
        global resume_reply,last_initialize
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        message=json.loads(body)
        self.log_request_data(message.get('method','response'))
        if mode=='auth':self.empty(401,{'WWW-Authenticate':'Basic realm="fixture"'});return
        if mode=='forbidden':self.empty(403);return
        if mode=='redirect':self.empty(307,{'Location':'http://localhost:%d/leak'%self.server.server_port});return
        if 'id' not in message:self.empty(202);return
        reply=json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result(message)}).encode()
        if mode.startswith('legacy'):
            messages.put(reply);self.empty(202);return
        self.send_response(200)
        self.send_header('Mcp-Session-Id','fixture-session')
        if mode=='json':
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(reply)));self.end_headers();self.wfile.write(reply);return
        self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
        try:
            if mode=='pending-body':
                while True:self.wfile.write(b'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"fixture","progress":1}}\n\n');self.wfile.flush();time.sleep(.01)
            elif mode=='event-flood':
                self.wfile.write(b'data: '+b'x'*65536);self.wfile.flush()
            elif mode=='comment-flood':
                while True:self.wfile.write(b':'+b'x'*255+b'\n');self.wfile.flush()
            elif mode=='resume' and message['method']=='initialize':
                resume_reply=reply
                self.wfile.write(b'id: 1\nretry: 1\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"probe","progress":1}}\n\n')
                self.wfile.write(b'id: 2\ndata: {\"jsonrpc\":')
                self.wfile.flush()
            else:
                # Split a multiline data event inside its field name and use CRLF.
                self.wfile.write(b'event: message\r\nid: response\r\nda');self.wfile.flush()
                time.sleep(.005)
                payload=b'\r\ndata: '.join(json.dumps(json.loads(reply),indent=1).encode().splitlines())
                self.wfile.write(b'ta: '+payload+b'\r\n\r\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError):record({'peerClosed':True})
        self.close_connection=True
    def do_GET(self):
        self.log_request_data(None)
        if mode=='resume' and self.headers.get('Last-Event-ID')!='1':self.empty(409);return
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
        try:
            if mode=='resume':
                self.wfile.write(b'event: message\nid: 2\ndata: '+resume_reply+b'\n\n');self.wfile.flush();self.close_connection=True;return
            endpoint=('/messages' if mode!='legacy-cross' else 'http://localhost:%d/messages'%self.server.server_port).encode()
            self.wfile.write(b'event: endpoint\ndata: '+endpoint+b'\n\n');self.wfile.flush()
            while True:
                try:reply=messages.get(timeout=.05);self.wfile.write(b'event: message\ndata: '+reply+b'\n\n')
                except queue.Empty:self.wfile.write(b': heartbeat\n\n')
                self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError):record({'peerClosed':True})
        self.close_connection=True

server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
endpoint='http://127.0.0.1:%d/mcp'%server.server_port
(root/'endpoint.pending').write_text(endpoint)
os.replace(root/'endpoint.pending',root/'endpoint')
server.serve_forever()
