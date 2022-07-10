#
# MethodHandler.py
# Copyright 2022 Aleksandr Orlov
# avo2000@mail.ru
# created: 2022-06-20 13:55:29
#

import numpy as np
import time
from timeit import default_timer
import threading
# tensorflow imported in TensorFlowModel._init_impl()
import tensorflow as tf

class ProcessingError(Exception):
    pass

class Model:
    UNCONNECTED = 0
    IDLE = 1
    BUSY = 2
    ERROR = 3
    
    statusStrings = (
        "UNCONNECTED",
        "IDLE",
        "BUSY",
        "ERROR"
    )
    
    def __init__(self,path,mutex):
        self._mutex = mutex
        self._status = self.UNCONNECTED
        self._path = path
        
    def name(self):
        return self._path

    def init(self):
        try:
            if not self._status == self.UNCONNECTED:
                raise ProcessingError('invalid model "%s" status: "%s"' %  self.name(), self.statusStrings[self._status])
            self._status = self.BUSY
            # processing ...
            status = self.ERROR
            self._init_impl()
            status = self.IDLE
        finally:
            self._status = status
                
    # call at the acquired mutex
    def predictSimple(self, shape, data):
        if not (self._status == self.IDLE):
            raise ProcessingError('invalid model "%s" status: "%s"' %  self.name(), self.statusStrings[self._status])
        # processing ...
        self._status = self.BUSY
        self._mutex.release()                
        try:        
            result = self._predictSimple(shape,data)
            return result
        finally:
            self._mutex.acquire()
            self._status = self.IDLE

    def _predictSimple(self,shape,data):
        start = default_timer()                 # time measurement
        r = len(shape)
        if (r < 2):
            raise ProcessingError('invalid shape')
        total_x = 1                             # maximal data length        
        for n in shape:
            if (not type(n) == int) or (n <= 0):
                raise ProcessingError('invalid shape')
            total_x *= n
        x = np.ndarray(total_x,np.float32)
        size = len(data)                        # real data length
        for i in range(total_x):
            if i < size:
                d = data[i]
                if not type(d) == float:
                    raise ProcessingError('invalid data type')                                
            else:
                d = 0.
            x[i] = d
        x = x.reshape(shape)
        y = self.xx_predictSimple(x)
        total_y = 1                             # maximal data length
        for n in y.shape:
            if (not type(n) == int) or (n <= 0):
                raise ProcessingError('invalid shape')
            total_y *= n
        shape_y = y.shape       
        y = y.reshape(total_y)
        out = []
        for i in range(total_y):
            out.append(float(y[i]))
        end = default_timer()                   # time measurement
        return [ list(shape_y), out, end - start ]

class SimulatedModel(Model):
    PATHS = ["models/net1Max.h5","models/net1Min.h5","models/net2Max.h5","models/net2Min.h5",]
    INPUT_SHAPES = ((1,22),(1,22),(1,60),(1,60),)
    OUTPUT_SHAPES = ((1,60),(1,60),(1,1),(1,1),)

    def _init_impl(self):
        if not self._path in self.PATHS:
            raise ProcessingError('unknown model: "%s"' % self._path)
        return

    def xx_predictSimple(self,x):
        ish = list(x.shape)
        ish[0] = 1
        ndx = self.PATHS.index(self._path)
        ishape = self.INPUT_SHAPES[ndx]
        if not tuple(ish) == ishape:
            raise ProcessingError('model "%s": shape is not compliant with requirements' % self.name())
        osh = list(self.OUTPUT_SHAPES[ndx])
        osh[0] = x.shape[0]        
        result = np.ndarray(osh,np.float32)
        result.fill(0.)
        time.sleep(0.1)        # Simulate long operation
        return result        

class TensorFlowModel(Model):

    def _init_impl(self):
        #import tensorflow as tf
        self.model = tf.keras.models.load_model(self._path)
        return

    def xx_predictSimple(self,x):
        predictions = self.model.predict(x)
        return predictions        
      
class TFModels:

    def __init__(self,modelclass):
        self._mutex = threading.Lock()
        self._models = []
        self._modelclass = modelclass

    def find_model(self,key):
        for m in self._models:
            if m.name() == key:         
                return m
        return None
        
    def get_model(self,modelpath):
        mdl = self.find_model(modelpath)
        if mdl == None:  
            mdl = self._modelclass(modelpath,self._mutex)
            self._models.append(mdl)
            self._mutex.release()                # release list mutex
            #... Init model
            try:
                mdl.init()                       # unprotected slow operation
            finally:
                self._mutex.acquire()            # acquire list mutex
        i = 0
        while not mdl._status == mdl.IDLE:
            if mdl._status == mdl.ERROR:
                raise ProcessingError('model "%s" not loaded' % mdl.name())
            if i > 15:
                raise ProcessingError('model "%s" access timeout' % mdl.name())
            self._mutex.release()                # release list mutex
            time.sleep(1)                             # unprotected slow operation
            i += 1
            self._mutex.acquire()                # acquire list mutex
        return mdl

class MethodHandler:
    
    def __init__(self, server, models):
        self._server = server
        self._models = models
        
    def close(self, password):
        if password == "12345":
            self._stoptimer = threading.Timer(1, self._server.stop)
            self._stoptimer.start()
            return "Issued an order to stop"
        return "incorrect password server is not stopped"
        
    def predictSimple(self,modelpath,shape,data):
        self._models._mutex.acquire()
        try:
            mdl = self._models.get_model(modelpath)
            #... Use model        
            return mdl.predictSimple(shape,data)
        finally:
            self._models._mutex.release()

    def raise_exception(self,code,msg):
        if code == 0:
            raise Exception('my custom exception "%s"' % msg)
        else:
            raise ProcessingError('my custom exception "%s"' % msg)
        return []

