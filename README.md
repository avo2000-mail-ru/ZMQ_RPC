# ZMQ_RPC
RPC for MQL using ZMQ and JSON

The initial goal of the work was to make a solution that allows you to call the Tensorflow model's predict method from an Expert Advisor running on a 32-bit Metatrader 4 terminal. Such a task is not relevant for the 64-bit Metatrader 5 terminal. From it, I call the model, referring through the wrapper DLL to tensorflow_сс.dll . For MT4, this cannot be done without IPC, that is, data transfer between different processes. I quickly discovered that there are no ready-made solutions for MT4 regarding RPC, with the exception of ZeroMQ. That is, the choice of the instrumental platform was predetermined. ZMQ transfers only a buffer between programs without any data marshalization. Therefore, I had to use Alexey Sergeev's JASON library for marshalization https://www.mql5.com/ru/code/13663. It fit perfectly. And, of course, MQL-ZMQ from Li Ding dingmaotu@hotmail.com, it can be downloaded from the link https://github.com/dingmaotu/mql-zmq. It was decided to make the server in Python, the native language for Tensorflow. For the server, the code from the XMLRPC server included in the basic Python package was partially used. The server is multithreaded, that is, it supports simultaneous access of several clients. To implement a multithreaded server, I used a solution from Guillaume Aubert (gaubert) <guillaume(dot)aubert(at)gmail(dot)com>. The server loads the model at the first access to it, in the future it is this instance that is used for all subsequent accesses. To avoid conflicts, the server uses a mutex to access the model. Different models are available to different clients at the same time. One model is available to only one client. The others will wait until the model is released at this time.
For example, I have prepared four keras models in the way described in the publication https://www.mql5.com/ru/articles/8502, and an advisor configured to work with them. The Advisor is a redesigned PythonOptimizExpert advisor from this publication. The rework is that my ADVISOR uses a call to the predict method of a remote model instead of using data obtained from the same model by reading a file.
Along the way, I discovered and fixed an error in MQL-ZMQ that did not allow the solution to work in MT5. The error is contained in the file Include\Mql\Lang\Native.mqh. The corrected file is located in my project at the relative path Include\Mql\Lang\Native.mqh.

Description of the files:
1.  server_ZMQ_tf.py – ZMQ_RPC server
2.  MethodHandler.py – ZMQ_RPC server module
3.  net1Max.h5 - keras model for server operation
4.  net1Min.h5 - keras model for server operation
5.  net2Max.h5 - keras model for server operation
6.  net2Min.h5 - keras model for server operation
7.  MyPythonOptimizExpert_MT4.set - parameter file for MT4 Expert Advisor
8.  MyPythonOptimizExpert_MT5.set - parameter file for MT5 Expert Advisor
9.  JAson.mqh - JSON library file
10.  ZmqRpc.mqh – file containing ZmqRpc classes for the Advisor
11. PythonOptimizExpert_zmq.ex5 - Expert Advisor executable for MT5
12. PythonOptimizExpert_zmq.ex4 - Expert Advisor executable for MT4
13. PythonOptimizExpert_zmq.mq5 - the source file of the Expert Advisor for MT5
14. PythonOptimizExpert_zmq.mq4 - source file of the Expert Advisor for MT4
14. Include\Mql\Lang\Native.mqh – corrected MQL-ZMQ file

HOWTO
1. Download and install Python version >= 3.8 (the specified version is needed for tensorflow 2.X)
2. Install Tensorflow with the command from the Windows command prompt: pip install tensorflow 
3. Install Zeromq with the command from the Windows command prompt: pip install zmq
4. Download and install MQL-ZMQ. Just copy the files from the archive to the designated places for them.
5. Replace the file Include\Mql\Lang\Native.mqh. If you don't plan to compile the code for MT5, then you don't have to.
6. Copy the project files to the selected folder.
7. Make the selected folder current in the Windows command prompt
8. Start the server with the command in the Windows command prompt with the command: python server_ZMQ_tf.py
9. Open the strategy tester in the MT5 terminal. Run a single test of the PythonOptimizExpert_zmq.ex5 Expert Advisor on EURUSD, 1H, load the test parameters from the MyPythonOptimizExpert_MT5.set
10. file. Open the strategy tester in the MT4 terminal. Run a single test of the PythonOptimizExpert_zmq.ex4 Expert Advisor on EURUSD, 1H, load the test parameters from the MyPythonOptimizExpert_MT4.set file
