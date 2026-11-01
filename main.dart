// Phone Mount Bridge
// ------------------------------------------------------------------
// Shows the streamer page (bundled in assets/web/index.html, served from
// http://localhost:8080 so the camera works - localhost counts as a secure
// context) and gives it a native USB serial link to the ESP32 (CP2102 etc).
//
// The page talks to this file through three JS handlers:
//   usbConnect    -> opens the first USB serial device at 115200
//   usbWrite(str) -> writes a string to the serial port
//   usbDisconnect -> closes the port
// and this file calls back into the page with:
//   window.onNativeUsbLine(line)      - a line the ESP32 printed
//   window.onNativeUsbDisconnected()  - cable pulled / port lost

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_serial_communication/flutter_serial_communication.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int kBaudRate = 115200;
const int kLocalPort = 8080;

final InAppLocalhostServer localhostServer = InAppLocalhostServer(
  documentRoot: 'assets/web',
  port: kLocalPort,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable(); // keep the screen (and the stream) alive
  await [Permission.camera, Permission.microphone].request();
  await localhostServer.start();
  runApp(const BridgeApp());
}

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BridgePage(),
    );
  }
}

class BridgePage extends StatefulWidget {
  const BridgePage({super.key});

  @override
  State<BridgePage> createState() => _BridgePageState();
}

class _BridgePageState extends State<BridgePage> {
  InAppWebViewController? _web;
  final FlutterSerialCommunication _serial = FlutterSerialCommunication();

  StreamSubscription? _msgSub;
  StreamSubscription? _connSub;
  bool _connected = false;
  String _lineBuffer = '';

  @override
  void dispose() {
    _msgSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  // ---- helpers to talk back to the page ----
  Future<void> _toPage(String fn, [String? arg]) async {
    final call = arg == null ? '$fn()' : '$fn(${jsonEncode(arg)})';
    try {
      await _web?.evaluateJavascript(
        source: 'if (window.$fn) { $call; }',
      );
    } catch (_) {}
  }

  String _eventToString(dynamic e) {
    if (e is Uint8List) return utf8.decode(e, allowMalformed: true);
    if (e is List) {
      return utf8.decode(List<int>.from(e), allowMalformed: true);
    }
    return e.toString();
  }

  void _onSerialData(dynamic event) {
    _lineBuffer += _eventToString(event);
    int idx;
    while ((idx = _lineBuffer.indexOf('\n')) != -1) {
      final line = _lineBuffer.substring(0, idx).trim();
      _lineBuffer = _lineBuffer.substring(idx + 1);
      if (line.isNotEmpty) _toPage('onNativeUsbLine', line);
    }
    if (_lineBuffer.length > 512) _lineBuffer = ''; // no-newline flood guard
  }

  void _onConnectionEvent(dynamic event) {
    final s = event.toString().toLowerCase();
    if (_connected &&
        (s.contains('false') ||
            s.contains('disconnect') ||
            s.contains('detach'))) {
      _connected = false;
      _toPage('onNativeUsbDisconnected');
    }
  }

  // ---- handlers the page calls ----
  Future<Map<String, dynamic>> _usbConnect() async {
    try {
      if (_connected) return {'ok': true, 'message': 'already connected'};

      final devices = await _serial.getAvailableDevices();
      if (devices.isEmpty) {
        return {
          'ok': false,
          'message': 'No USB serial device found. Check cable / OTG.'
        };
      }

      final ok = await _serial.connect(devices.first, kBaudRate);
      if (!ok) {
        return {
          'ok': false,
          'message':
              'connect() returned false - USB permission denied or port busy.'
        };
      }

      _connected = true;
      _lineBuffer = '';
      _msgSub?.cancel();
      _connSub?.cancel();
      _msgSub = _serial
          .getSerialMessageListener()
          .receiveBroadcastStream()
          .listen(_onSerialData);
      _connSub = _serial
          .getDeviceConnectionListener()
          .receiveBroadcastStream()
          .listen(_onConnectionEvent);

      return {'ok': true, 'message': 'connected'};
    } catch (e) {
      return {'ok': false, 'message': e.toString()};
    }
  }

  Future<bool> _usbWrite(String data) async {
    if (!_connected) return false;
    try {
      return await _serial.write(Uint8List.fromList(utf8.encode(data)));
    } catch (_) {
      return false;
    }
  }

  Future<bool> _usbDisconnect() async {
    try {
      _msgSub?.cancel();
      _connSub?.cancel();
      _msgSub = null;
      _connSub = null;
      await _serial.disconnect();
    } catch (_) {}
    _connected = false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: InAppWebView(
          initialUrlRequest:
              URLRequest(url: WebUri('http://localhost:$kLocalPort/index.html')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            domStorageEnabled: true,
            useHybridComposition: true,
          ),
          onWebViewCreated: (controller) {
            _web = controller;
            controller.addJavaScriptHandler(
              handlerName: 'usbConnect',
              callback: (args) => _usbConnect(),
            );
            controller.addJavaScriptHandler(
              handlerName: 'usbWrite',
              callback: (args) =>
                  _usbWrite(args.isNotEmpty ? args[0].toString() : ''),
            );
            controller.addJavaScriptHandler(
              handlerName: 'usbDisconnect',
              callback: (args) => _usbDisconnect(),
            );
          },
          // The page asks for camera/mic - allow it (Android runtime
          // permissions were already requested in main()).
          onPermissionRequest: (controller, request) async {
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
        ),
      ),
    );
  }
}
