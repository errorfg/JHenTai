import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:volume_key_board/volume_key_board.dart';

import 'jh_service.dart';
import 'log.dart';

VolumeService volumeService = VolumeService();

class VolumeService extends GetxService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final MethodChannel methodChannel;

  Function(VolumeEventType)? _onData;

  static const int volumeUp = 1;
  static const int volumeDown = -1;

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (GetPlatform.isAndroid) {
      methodChannel = const MethodChannel('com.gallery.reader.volume.event.intercept');
    }
  }

  @override
  void onClose() {
    super.onClose();
    cancelListen();
  }

  Future<void> setInterceptVolumeEvent(bool value) async {
    if (GetPlatform.isAndroid) {
      try {
        await methodChannel.invokeMethod('set', value);
      } on PlatformException catch (e) {
        log.error('Set intercept volume event error!', e);
        log.uploadError(e);
      }
    } else if (GetPlatform.isIOS) {
      if (value && _onData != null) {
        VolumeKeyBoard.instance.addListener(_onVolumeKeyEvent);
      } else {
        VolumeKeyBoard.instance.removeListener();
      }
    }
  }

  void _onVolumeKeyEvent(VolumeKey event) {
    if (event == VolumeKey.up) {
      _onData?.call(VolumeEventType.volumeUp);
    } else if (event == VolumeKey.down) {
      _onData?.call(VolumeEventType.volumeDown);
    }
  }

  void listen(Function(VolumeEventType)? onData) {
    _onData = onData;

    if (GetPlatform.isAndroid) {
      methodChannel.setMethodCallHandler((MethodCall call) {
        if (call.method == 'event') {
          final int eventType = call.arguments as int;
          if (eventType == volumeUp) {
            onData?.call(VolumeEventType.volumeUp);
          } else if (eventType == volumeDown) {
            onData?.call(VolumeEventType.volumeDown);
          }
        }
        return Future.value();
      });
    }
  }

  void cancelListen() {
    if (GetPlatform.isAndroid) {
      methodChannel.setMethodCallHandler(null);
    } else if (GetPlatform.isIOS) {
      VolumeKeyBoard.instance.removeListener();
    }
    _onData = null;
  }
}

enum VolumeEventType { volumeUp, volumeDown }
