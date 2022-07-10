//+------------------------------------------------------------------+
//|                                                       ZmqRpc.mqh |
//|                                   Copyright 2022 Aleksandr Orlov |
//|                                                  avo2000@mail.ru |
//|                                     created: 2022-06-09 16:53:29 |
//+------------------------------------------------------------------+
#property strict

#ifndef ERROR
#define ERROR(p) Print(p)
#endif
#ifndef INFO
#define INFO(p) Print(p)
#endif
#include <Zmq/Zmq.mqh>
#include "JAson.mqh"

//+------------------------------------------------------------------+
class ZmqClient {
 protected:
  string            _address;
  Context           _context;
  Socket            _requester;
  bool              _is_fault;
  string            _faultString;
  int               _faultCode;
  double            _timeout;
  
 public:
  ZmqClient(string addr) : _requester(_context,ZMQ_REQ), _address(addr), _timeout(3.0) {
  }
  
  bool connect() {
    _requester.connect(_address);
    return true;
  }
  
  bool disconnect() {
    _requester.disconnect(_address);
    return true;
  }
  
  bool execute( CJAVal &args, CJAVal &result) {
    string request = "";
    args.Serialize(request);

    ZmqMsg message(request);
    _requester.send(message);

    PollItem items[1];
    _requester.fillPollItem(items[0],ZMQ_POLLIN);
    int tout = int(_timeout * 1000.0);    
    _requester.poll(items,tout);
    
    bool success = false;
    
    if ((items[0].revents & ZMQ_POLLIN) != 0) {
      ZmqMsg reply;
      _requester.recv(reply,true);

      string rply = reply.getData();
      success = result.Deserialize(rply);
      if ( success ) {
        if ( result.m_type == enJAType::jtOBJ ) {
          _is_fault = true;
          _faultCode = (int)result["faultCode"].ToInt();
          _faultString = result["faultString"].ToStr();
        }
        else {
          _is_fault = false;
          _faultCode = 0;
          _faultString = "";
        }
      }
      else {
        ERROR(StringFormat("JSON deserialize failed, message: %s",rply));
      }
    }

    return success;
  }
  
  bool              isFault() { return _is_fault; }
  string            faultString() { return _faultString; }
  int               faultCode() { return _faultCode; }

  void              timeout(double t) { _timeout = t; }
};

//+------------------------------------------------------------------+
class CModelZmq {
protected:
  ZmqClient*         _client;
  string             _path;
  int                _input_shape[];
  int                _output_shape[];
  int                _input_size;
  int                _output_size;

public:

                     CModelZmq( ZmqClient* cl) : _client(cl) {}

  bool               init( const string path,
                           const int &input_shape[],
                           const int &output_shape[]) {
    _path = path;
    if ( !copyShape(input_shape,_input_shape,_input_size) ) {
      ERROR("invalid input shape");
      return false;
    }
    if ( !copyShape(output_shape,_output_shape,_output_size) ) {
      ERROR("invalid output shape");
      return false;
    }
    return true;
  }

  static bool copyShape(const int &src[],int &dst[],int &size) {
    int total = ArraySize(src);
    if ( total < 2 ) {
      return false;
    }
    ArrayResize(dst,total);
    size = 1;
    for ( int i = 0; i < total; ++i ) {
      if (src[i] == 0) {
        return false;
      }
      dst[i] = src[i];
      size *= src[i];
    }
    return true;
  }
  
  int                getInputSize() {
    return _input_size;
  }

  int                getOutputSize() {
    return _output_size;
  }

  bool predict(const double &src[], int input_size, double &dst[], int output_size, double &time1, double &time2) {
    ulong start = GetMicrosecondCount();
    
    CJAVal args, result;

    args["method"] = "predictSimple";
    args["params"][0] = _path;
    for ( int i = 0; i < ArraySize(_input_shape); ++i ) {
      args["params"][1][i] = _input_shape[i];
    }
    for ( int i = 0; i < input_size; ++i ) {
      args["params"][2][i] = src[i];
    }

    if ( !_client.execute(args,result) ) {
      ERROR("client.execute failed");
      return false;
    }
    if ( _client.isFault() ) {
      int faultCode = (int)result["faultCode"].ToInt();
      string faultString = result["faultString"].ToStr();
      ERROR(StringFormat("fault: code=%d, string=\"%s\"",faultCode,faultString));
      return false;
    }
    // Проверим, что result - массив размера >= 3
    enJAType type = result.m_type;
    if ( type != enJAType::jtARRAY ) {
      ERROR(StringFormat("invalid result type: %s, expecting array",EnumToString(type)));
      return false;
    }
    int size = result.Size();
    if ( size < 3 ) {
      ERROR(StringFormat("invalid result size: %d, expecting 3",size));
      return false;
    }
    // Проверим, что result[0] - совпадающий с output_shape массив
    type = result[0].m_type;
    if ( type != enJAType::jtARRAY ) {
      ERROR(StringFormat("invalid result[0] type: %s, expecting array",EnumToString(type)));
      return false;
    }
    size = result[0].Size();
    if ( size != ArraySize(_output_shape)) {
       ERROR(StringFormat("invalid result[0] size: %d, expecting %d",size,ArraySize(_output_shape)));
      return false;
    }
    for (int i = 0; i < size; ++i) {
      type = result[0][i].m_type;
      if ( type != enJAType::jtINT ) {
        ERROR(StringFormat("invalid result[0][%d] type: %s, expecting int",i,EnumToString(type)));
        return false;
      }
      int val = (int)result[0][i].ToInt();
      if ( val != _output_shape[i] ) {
        ERROR(StringFormat("invalid result[0][%d]: %d, expecting %d",i,val,_output_shape[i]));
        return false;
      }
    }
   
    // Проверим, что result[1] - массив
    type = result[1].m_type;
    if ( type != enJAType::jtARRAY ) {
      ERROR(StringFormat("invalid result[1] type: %s, expecting array",EnumToString(type)));
      return false;
    }
    // Копируем result[1]
    size = result[1].Size();
    if ( size > output_size) {
      size = output_size;
    }
    if (ArraySize(dst) < size) {
      if ( ArrayResize(dst,size) == -1 ) {
        size = ArraySize(dst);
      }
    }
    for ( int i = 0; i < size; ++i ) {
      type = result[1][i].m_type;
      if ( type != enJAType::jtDBL ) {
        ERROR(StringFormat("invalid result[1][%d] type: %s, expecting double",i,EnumToString(type)));
        return false;
      }
      dst[i] = result[1][i].ToDbl();
    }
    type = result[2].m_type;
    if ( type != enJAType::jtDBL ) {
      ERROR(StringFormat("invalid result[2] type: %s, expecting double",EnumToString(type)));
        return false;
      }
    time2 += result[2].ToDbl();
    ulong end = GetMicrosecondCount();
    time1 += ((end - start) / 1000000.);    
    return true;
  }
};

//+------------------------------------------------------------------+

