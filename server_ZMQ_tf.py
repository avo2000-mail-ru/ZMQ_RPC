"""

   Multithreaded stopable Tensorflow models predict server

"""
import getopt
import sys
import time
import threading
import zmq
from zmq import devices
from zmq.utils.win32 import allow_interrupt
import json
from MethodHandler import TFModels, TensorFlowModel, MethodHandler

class Flags:
    def __init__(self):
        self.shutdown = False
        self.threads = 0
        
sw = Flags()

class Options:
    def __init__(self):
        self.addr = "tcp://*"
        self.port = 50506
        self.nworkers = 5

opts = Options()        

print ("ZeroMQ version sanity-check: %s" % zmq.__version__)

def dumps(params):
    """data -> marshalled data

    Convert an argument tuple or a Fault instance to an ZMQ-RPC
    response.
    """

    assert isinstance(params, (tuple, Fault)), "argument must be tuple or Fault instance"
    if isinstance(params, Fault):
        params = { "faultCode" : params.faultCode, "faultString" : params.faultString, }    
    data = json.dumps(params)
    return "".join(data)

def loads(data):
    """data -> unmarshalled data, method name

    Convert an ZMQ-RPC packet to unmarshalled data plus a method
    name (None if not present).

    If the ZMQ-RPC packet represents a fault condition, this function
    raises a Fault exception.
    """
    request = json.loads(data)
    assert isinstance(request, (dict)), "argument must be dict instance"
    return request["params"], request["method"] 

def resolve_dotted_attribute(obj, attr, allow_dotted_names=True):
    """resolve_dotted_attribute(a, 'b.c.d') => a.b.c.d

    Resolves a dotted attribute name to an object.  Raises
    an AttributeError if any attribute in the chain starts with a '_'.

    If the optional allow_dotted_names argument is false, dots are not
    supported and this function operates similar to getattr(obj, attr).
    """

    if allow_dotted_names:
        attrs = attr.split('.')
        #print(1,attrs)
    else:
        attrs = [attr]
        #print(2,attrs)

    for i in attrs:
        if i.startswith('_'):
            raise AttributeError(
                'attempt to access private attribute "%s"' % i
                )
        else:
            #print(3,i)
            obj = getattr(obj,i)
            #print(4,obj)
    return obj

class Error(Exception):
    """Base class for client errors."""
    def __str__(self):
        return repr(self)

##
# Indicates an ZMQ-RPC fault response package.  This exception is
# raised by the unmarshalling layer, if the ZMQ-RPC response contains
# a fault string.  This exception can also be used as a class, to
# generate a fault ZMQ-RPC message.
#
# @param faultCode The ZMQ-RPC fault code.
# @param faultString The ZMQ-RPC fault string.

class Fault(Error):
    """Indicates an ZMQ fault package."""
    def __init__(self, faultCode, faultString, **extra):
        Error.__init__(self)
        self.faultCode = faultCode
        self.faultString = faultString
    def __repr__(self):
        return "<%s %s: %r>" % (self.__class__.__name__,
                                self.faultCode, self.faultString)

class RPCRequestHandler:
    def __init__(self,server):
        self.server = server
        self.path = ""

    def handle_request(self,data):
            data = data.decode('utf-8')
            response = self.server._marshaled_dispatch(
                    data, getattr(self, '_dispatch', None), self.path
                )
            return response.encode('utf-8')

class SimpleRPCDispatcher:

    def __init__(self):
        self.funcs = {}
        self.instance = None
        self.allow_dotted_names = False

    def register_instance(self, instance):

        self.instance = instance

    def register_function(self, function=None, name=None):
        # decorator factory
        if function is None:
            return partial(self.register_function, name=name)

        if name is None:
            name = function.__name__
        self.funcs[name] = function

        return function

    def _marshaled_dispatch(self, data, dispatch_method = None, path = None):

        try:
            params, method = loads(data)

            # generate response
            if dispatch_method is not None:
                response = dispatch_method(method, params)
            else:
                response = self._dispatch(method, params)
            # wrap response in a singleton tuple
            response = tuple(response)
            response = dumps(response)
        except Fault as fault:
            response = dumps(fault)
        except:
            # report exception back to server
            exc_type, exc_value, exc_tb = sys.exc_info()
            try:
                response = dumps(
                    Fault(1, "%s:%s" % (exc_type, exc_value))
                    )
            finally:
                # Break reference cycle
                exc_type = exc_value = exc_tb = None

        return response

    def _dispatch(self, method, params):

        try:
            # call the matching registered function
            func = self.funcs[method]
        except KeyError:
            pass
        else:
            if func is not None:
                return func(*params)
            raise Exception('method "%s" is not supported' % method)

        if self.instance is not None:
            if hasattr(self.instance, '_dispatch'):
                # call the `_dispatch` method on the instance
                return self.instance._dispatch(method, params)

            # call the instance's method directly
            try:
                func = resolve_dotted_attribute(
                    self.instance,
                    method,
                    self.allow_dotted_names
                )
                
            except AttributeError:
                pass
            else:
                if func is not None:
                    return func(*params)

        raise Exception('method "%s" is not supported' % method)
        
class ZMQWorker(threading.Thread):
    def __init__(self, target = None, args = ()):
        threading.Thread.__init__(self)
        self.aWorker_URL = args[0]
        self.aContext = args[1]
        self.server = args[2]
        self.requestCount = 0; 

    def run(self):
        def interrupt_polling():
            #print('Caught CTRL-C!')
            sw.shutdown = True
            
        def poll_socket(socket, timetick = 100):
            poller = zmq.Poller()
            poller.register(socket, zmq.POLLIN)
            # wait up to 100msec
            while True:
                try:
                    obj = dict(poller.poll(timetick))
                    if sw.shutdown:
                        return None
                    if socket in obj and obj[socket] == zmq.POLLIN:
                        return socket.recv()
                except KeyboardInterrupt: 
                    sw.shutdown = True
                    #print('Caught KeyboardInterrupt (CTRL-C)',sw.shutdown)
                    return None
            # Escape while loop if there's a keyboard interrupt.
            
        sw.threads += 1
        
        """Worker routine"""
        #Context to get inherited or create a new one trick------------------------------
        aContext = self.aContext or zmq.Context.instance()
        
        # Socket to talk to dispatcher --------------------------------------------------
        socket = aContext.socket( zmq.REP )
        
        socket.connect( self.aWorker_URL )
        
        handler = RPCRequestHandler(self.server)
            
        memory = {}
    
        while True:
    
            with allow_interrupt(interrupt_polling):
                msg = poll_socket(socket)
            if sw.shutdown:
                break
    
            # print( "Received request: [ %s ]" % ( msg ) )
            self.requestCount += 1
            print( "Received request %d" % self.requestCount )
                       
            # do some 'work' ------------------------------------------------------------
            try:
                response = handler.handle_request(msg)
            except Exception as e:
                print(e)
                response = b""

            #send reply back to client, who asked ---------------------------------------
            socket.send( response )
            
        sw.threads -= 1
    
class StoppableThreadingZMQServer(SimpleRPCDispatcher, threading.Thread):    
    def __init__(self):
        SimpleRPCDispatcher.__init__(self)
        threading.Thread.__init__(self)
    
    def run(self):
        """Server routine"""
        url_client = "{addr}:{port}".format(addr = opts.addr, port = opts.port)
        url_worker = "inproc://workers"
    
        # --------------------------------------------------------------------||||||||||||--
        # Launch pool of worker threads --------------< or spin-off by one in OnDemandMODE >
        for i in range(5):
            thread = ZMQWorker(target = None, args = (url_worker,None,self,))
            thread.start()
    
        dev = devices.ThreadDevice(zmq.QUEUE, zmq.ROUTER, zmq.DEALER)
        dev.bind_in(url_client)
        dev.bind_out(url_worker)
        dev.setsockopt_in(zmq.IDENTITY, b'ROUTER')
        dev.setsockopt_out(zmq.IDENTITY, b'DEALER')
        dev.start()
        
        print ("The ZeroMQ server listens %s" % url_client )
        print ("It can be terminated with CTRL+C or CTRL+PAUSE.")   
        
        while not sw.shutdown:
            try:
                time.sleep(0.1)
            except KeyboardInterrupt:
                break    
        while sw.threads > 0:    
            time.sleep(0.1)
            
        print ("Thread ended")
    
        del dev
        
    def stop(self):
        sw.shutdown = True


def usage():
    print("not implemented")

def main():
    try:
        options, args = getopt.getopt(sys.argv[1:], "ha:p:w:v?", ["help", "address=", "port=", "workers=",])
    except getopt.GetoptError as err:
        # print help information and exit:
        print(err)  # will print something like "option -a not recognized"
        usage()
        sys.exit(2)
    output = None
    verbose = False
    for o, a in options:
        if o == "-v":
            verbose = True
        elif o in ("-?", "-h", "--help"):
            usage()
            sys.exit()
        elif o in ("-a", "--address"):
            opts.addr = a
        elif o in ("-p", "--port"):
            opts.port = int(a)
        elif o in ("-w", "--workers"):
            opts.nworkers = int(a)
        else:
            assert False, "unhandled option"

    print("ZMQ-rpc server starting address=%s, port=%d, workers=%d" % (opts.addr, opts.port, opts.nworkers))
    
    server = StoppableThreadingZMQServer()
    models = TFModels(TensorFlowModel)
    handler = MethodHandler(server,models)
    server.register_instance(handler)

    server.start()
    try:
        while server.is_alive():
            time.sleep(0.1)
    except KeyboardInterrupt:
        server.stop()
        
if __name__ == "__main__":
    main()
