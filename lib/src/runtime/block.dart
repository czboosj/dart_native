import 'dart:ffi';

import 'package:dart_objc/runtime.dart';
import 'package:dart_objc/src/common/channel_dispatch.dart';
import 'package:dart_objc/src/common/library.dart';
import 'package:dart_objc/src/foundation/native_type_box.dart';
import 'package:dart_objc/src/common/pointer_encoding.dart';
import 'package:dart_objc/src/runtime/id.dart';
import 'package:dart_objc/src/runtime/native_runtime.dart';
import 'package:dart_objc/src/runtime/selector.dart';
import 'package:ffi/ffi.dart';

typedef DOBlockTypeEncodeStringC = Pointer<Utf8> Function(Pointer<Void> block);
typedef DOBlockTypeEncodeStringD = Pointer<Utf8> Function(Pointer<Void> block);
final DOBlockTypeEncodeStringD blockTypeEncodeString = runtimeLib
    .lookupFunction<DOBlockTypeEncodeStringC, DOBlockTypeEncodeStringD>(
        'DOBlockTypeEncodeString');

Map<int, Block> _blockForAddress = {};

class Block extends id {
  Function function;
  NSObject _wrapper; // Block hold wrapper
  List<String> types = [];

  factory Block(Function function) {
    List<String> types = _typeStringForFunction(function);
    Pointer<Utf8> typeStringPtr = Utf8.toUtf8(types.join(', '));
    NSObject blockWrapper =
        NSObject.fromPointer(blockCreate(typeStringPtr, _callbackPtr));
    int blockAddr = blockWrapper.perform(Selector('blockAddress'));
    Block result = Block._internal(Pointer.fromAddress(blockAddr));
    typeStringPtr.free();
    result.types = types;
    result._wrapper = blockWrapper;
    result.function = function;
    _blockForAddress[result.pointer.address] = result;
    return result;
  }

  factory Block.fromPointer(Pointer<Void> ptr) {
    return Block._internal(ptr);
  }

  Block._internal(Pointer<Void> ptr) : super(ptr) {
    ChannelDispatch().registerChannelCallback('block_invoke', _asyncCallback);
  }

  Class get superclass {
    return isa.perform(Selector('superclass'));
  }

  String get description {
    return toString();
  }

  String get debugDescription {
    return toString();
  }

  int get hash {
    return hashCode;
  }

  Block copy() {
    Pointer<Void> newPtr = Block_copy(pointer);
    if (newPtr == pointer) {
      return this;
    }
    Block result = Block._internal(newPtr);
    // Block created by function.
    if (function != null) {
      result._wrapper = _wrapper;
      result.function = function;
      _blockForAddress[newPtr.address] = result;
      result.types = types;
    }
    return result;
  }

  dealloc() {
    _wrapper = null;
    _blockForAddress.remove(pointer.address);
    super.dealloc();
  }

  dynamic invoke([List args]) {
    if (pointer == nullptr) {
      return null;
    }
    Pointer<Utf8> typesEncodingsPtr = blockTypeEncodeString(pointer);
    Pointer<Int32> countPtr = Pointer<Int32>.allocate();
    Pointer<Pointer<Utf8>> typesPtrPtr =
        nativeTypesEncoding(typesEncodingsPtr, countPtr, 0);
    int count = countPtr.load();
    countPtr.free();
    // typesPtrPtr contains return type and block itself.
    if (count != (args?.length ?? 0) + 2) {
      throw 'Args Count NOT match';
    }
    Pointer<Pointer<Void>> argsPtrPtr = nullptr.cast();
    List<Function> closures = [];
    if (args != null) {
      argsPtrPtr = Pointer<Pointer<Void>>.allocate(count: args.length);
      for (var i = 0; i < args.length; i++) {
        if (args[i] == null) {
          throw 'One of args list is null';
        }
        String encoding = Utf8.fromUtf8(typesPtrPtr.elementAt(i + 2).load());
        Function closure =
            storeValueToPointer(args[i], argsPtrPtr.elementAt(i), encoding);
        if (closure != null) {
          closures.add(closure);
        }
      }
    }
    Pointer<Void> resultPtr = blockInvoke(pointer, argsPtrPtr);
    if (argsPtrPtr != nullptr.cast()) {
      argsPtrPtr.free();
    }
    String encoding = Utf8.fromUtf8(typesPtrPtr.elementAt(0).load());
    dynamic result = loadValueFromPointer(resultPtr, encoding);

    for (Function function in closures) {
      Function.apply(function, []);
    }
    return result;
  }
}

Pointer<NativeFunction<BlockCallbackC>> _callbackPtr =
    Pointer.fromFunction(_syncCallback);

_callback(Pointer<Void> blockPtr, Pointer<Pointer<Pointer<Void>>> argsPtrPtr,
    Pointer<Pointer<Void>> retPtr, int argCount) {
  Block block = _blockForAddress[blockPtr.address];
  if (block == null) {
    return null;
  }
  List args = [];
  Pointer pointer = block._wrapper.perform(Selector('typeEncodings'));
  Pointer<Pointer<Utf8>> typesPtrPtr = pointer.cast();
  for (var i = 0; i < argCount; i++) {
    // Get block args encoding. First is return type.
    String encoding = nativeTypeEncoding(typesPtrPtr.elementAt(i + 1).load())
        .load()
        .toString();
    Pointer ptr = argsPtrPtr.elementAt(i).load();
    if (!encoding.startsWith('{')) {
      ptr = ptr.cast<Pointer<Void>>().load();
    }
    dynamic value = loadValueFromPointer(ptr, encoding);
    dynamic arg = boxForValue(block.types[i + 1], value);
    args.add(arg);
  }
  dynamic result = Function.apply(block.function, args);

  if (retPtr != null) {
    String encoding =
        nativeTypeEncoding(typesPtrPtr.elementAt(0).load()).load().toString();
    Function closure = storeValueToPointer(result, retPtr, encoding);
    if (closure != null) {
      throw 'Return value of callback may leak.';
    }
  }
  return result;
}

_syncCallback(
    Pointer<Void> blockPtr,
    Pointer<Pointer<Pointer<Void>>> argsPtrPtr,
    Pointer<Pointer<Void>> retPtr,
    int argCount) {
  _callback(blockPtr, argsPtrPtr, retPtr, argCount);
}

dynamic _asyncCallback(int blockAddr, int argsAddr, int argCount) {
  Pointer<Void> blockPtr = Pointer.fromAddress(blockAddr);
  Pointer<Pointer<Pointer<Void>>> argsPtrPtr = Pointer.fromAddress(argsAddr);
  return _callback(blockPtr, argsPtrPtr, null, argCount);
}

Map<String, String> _nativeTypeNameMap = {
  'unsigned_short': 'unsigned short',
  'unsigned_int': 'unsigned int',
  'unsigned_long': 'unsigned long',
  'long_long': 'long long',
  'unsigned_long_long': 'unsigned long long',
};

List<String> _nativeTypeNames = [
  'id',
  'BOOL',
  'int',
  'void',
  'char',
  'char',
  'short',
  'unsigned short',
  'unsigned int',
  'long',
  'unsigned long',
  'long long',
  'unsigned long long',
  'float',
  'double',
  'bool',
  'size_t',
  'CGFloat',
  'CGSize',
  'CGRect',
  'CGPoint',
  'CGVector',
  'NSRange',
  'NSInteger',
  'NSUInteger',
  'Class',
  'SEL',
  'Selector'
];

List<String> _typeStringForFunction(Function function) {
  String typeString = function.runtimeType.toString();
  List<String> argsAndRet = typeString.split(' => ');
  if (argsAndRet.length == 2) {
    String args = argsAndRet.first;
    String ret = argsAndRet.last.replaceAll('Null', 'void');
    if (args.length > 2) {
      args = args.substring(1, args.length - 1);
      _nativeTypeNameMap.forEach((String dartTypeName, String nativeTypeName) {
        args = args.replaceAll(dartTypeName, nativeTypeName);
      });
      return '$ret, $args'.split(', ').map((String s) {
        if (s.contains('Pointer')) {
          return 'ptr';
        } else if (s.contains('Function')) {
          return 'block';
        } else if (!_nativeTypeNames.contains(s)) {
          return 'NSObject';
        }
        return s;
      }).toList();
    } else {
      return [ret];
    }
  }
  return [];
}
