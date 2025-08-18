import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:chatview/chatview.dart';
import 'package:chatview/src/extensions/extensions.dart';
import 'package:chatview/src/models/voice_message_configuration.dart';
import 'package:chatview/src/widgets/reaction_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class VoiceMessageView extends StatefulWidget {
  const VoiceMessageView({
    Key? key,
    required this.screenWidth,
    required this.message,
    required this.isMessageBySender,
    this.inComingChatBubbleConfig,
    this.outgoingChatBubbleConfig,
    this.onMaxDuration,
    this.messageReactionConfig,
    this.config,
  }) : super(key: key);

  /// Provides configuration related to voice message.
  final VoiceMessageConfiguration? config;

  /// Allow user to set width of chat bubble.
  final double screenWidth;

  /// Provides message instance of chat.
  final Message message;
  final Function(int)? onMaxDuration;

  /// Represents current message is sent by current user.
  final bool isMessageBySender;

  /// Provides configuration of reaction appearance in chat bubble.
  final MessageReactionConfiguration? messageReactionConfig;

  /// Provides configuration of chat bubble appearance from other user of chat.
  final ChatBubble? inComingChatBubbleConfig;

  /// Provides configuration of chat bubble appearance from current user of chat.
  final ChatBubble? outgoingChatBubbleConfig;

  @override
  State<VoiceMessageView> createState() => _VoiceMessageViewState();
}

class _VoiceMessageViewState extends State<VoiceMessageView> with WidgetsBindingObserver {
  PlayerController? controller;
  StreamSubscription<PlayerState>? playerStateSubscription;

  final ValueNotifier<PlayerState> _playerState =
  ValueNotifier(PlayerState.stopped);

  final ValueNotifier<bool> _isLoading = ValueNotifier(false);
  final ValueNotifier<bool> _isPrepared = ValueNotifier(false);
  final ValueNotifier<String?> _errorMessage = ValueNotifier(null);

  String? _localFilePath;
  bool _isDownloading = false;

  PlayerState get playerState => _playerState.value;
  bool get isLoading => _isLoading.value;
  bool get isPrepared => _isPrepared.value;
  String? get errorMessage => _errorMessage.value;

  PlayerWaveStyle playerWaveStyle = const PlayerWaveStyle(scaleFactor: 70);

  static final Map<String, String> _downloadedFiles = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeController();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (!isPrepared && errorMessage == null) {
        _reinitializeAudio();
      }
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseIfPlaying();
    }
  }

  void _initializeController() {
    try {
      controller = PlayerController();
      playerStateSubscription = controller!.onPlayerStateChanged
          .listen((state) {
        _playerState.value = state;

        // Automatically seek to zero when audio completes
        if (state == PlayerState.stopped) {
          Future.delayed(Duration(milliseconds: 200), () async {
            try {
              await controller?.seekTo(0);
              debugPrint('تم الرجوع للبداية تلقائياً');
            } catch (e) {
              debugPrint('خطأ في الرجوع للبداية: $e');
            }
          });
        }
      });
      _initializeAudio();
    } catch (e) {
      _setError('خطأ في إنشاء مشغل الصوت: $e');
    }
  }

  void _pauseIfPlaying() {
    try {
      if (controller != null && playerState.isPlaying) {
        controller!.pausePlayer();
      }
    } catch (e) {
      debugPrint('خطأ في إيقاف التشغيل: $e');
    }
  }

  Future<void> _reinitializeAudio() async {
    if (_isDownloading) return;

    _clearError();

    try {
      if (controller == null) {
        _initializeController();
        return;
      }

      if (!isPrepared) {
        await _initializeAudio();
      }
    } catch (e) {
      _setError('خطأ في إعادة تهيئة الصوت: $e');
      _disposeController();
      _initializeController();
    }
  }

  void _setError(String error) {
    _errorMessage.value = error;
    _isPrepared.value = false;
    debugPrint(error);
  }

  void _clearError() {
    _errorMessage.value = null;
  }

  bool _isNetworkUrl(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
  }

  String _generateSafeFileName(String networkUrl) {
    final bytes = utf8.encode(networkUrl);
    final digest = md5.convert(bytes);

    final uri = Uri.tryParse(networkUrl);
    String extension = '.mp3';

    if (uri != null && uri.path.isNotEmpty) {
      final path = uri.path.toLowerCase();
      if (path.endsWith('.mp3')) extension = '.mp3';
      else if (path.endsWith('.wav')) extension = '.wav';
      else if (path.endsWith('.m4a')) extension = '.m4a';
      else if (path.endsWith('.aac')) extension = '.aac';
    }

    return 'voice_${digest.toString()}$extension';
  }

  Future<void> _initializeAudio() async {
    if (controller == null) return;

    final audioPath = widget.message.message;
    _isPrepared.value = false;
    _clearError();

    try {
      if (_isNetworkUrl(audioPath)) {
        await _downloadAndPrepareAudio(audioPath);
      } else {
        await _prepareLocalAudio(audioPath);
      }
    } catch (e) {
      _setError('خطأ في تحضير الصوت: $e');
    }
  }

  Future<void> _prepareLocalAudio(String localPath) async {
    if (controller == null) return;

    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('الملف الصوتي غير موجود');
      }

      await controller!.preparePlayer(
        path: localPath,
        noOfSamples: widget.config?.playerWaveStyle
            ?.getSamplesForWidth(widget.screenWidth * 0.5) ??
            playerWaveStyle.getSamplesForWidth(widget.screenWidth * 0.5),
      );

      _isPrepared.value = true;
      widget.onMaxDuration?.call(controller!.maxDuration);
    } catch (e) {
      _setError('خطأ في تحضير الصوت المحلي: $e');
    }
  }

  Future<void> _downloadAndPrepareAudio(String networkUrl) async {
    if (_isDownloading || controller == null) return;

    if (_downloadedFiles.containsKey(networkUrl)) {
      final cachedPath = _downloadedFiles[networkUrl]!;
      final file = File(cachedPath);

      if (await file.exists()) {
        _localFilePath = cachedPath;
        await _prepareAudioFromFile(cachedPath);
        return;
      } else {
        _downloadedFiles.remove(networkUrl);
      }
    }

    _isDownloading = true;
    _isLoading.value = true;

    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = _generateSafeFileName(networkUrl);
      final file = File('${tempDir.path}/$fileName');

      final response = await http.get(Uri.parse(networkUrl));

      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        _localFilePath = file.path;

        _downloadedFiles[networkUrl] = file.path;

        await _prepareAudioFromFile(file.path);
      } else {
        throw Exception('فشل في تحميل الملف الصوتي: ${response.statusCode}');
      }
    } catch (e) {
      _setError('خطأ في تحميل الصوت من الإنترنت: $e');
    } finally {
      _isLoading.value = false;
      _isDownloading = false;
    }
  }

  Future<void> _prepareAudioFromFile(String filePath) async {
    if (controller == null) return;

    try {
      await controller!.preparePlayer(
        path: filePath,
        noOfSamples: widget.config?.playerWaveStyle
            ?.getSamplesForWidth(widget.screenWidth * 0.5) ??
            playerWaveStyle.getSamplesForWidth(widget.screenWidth * 0.5),
      );

      _isPrepared.value = true;
      widget.onMaxDuration?.call(controller!.maxDuration);
    } catch (e) {
      _setError('خطأ في تحضير الملف الصوتي: $e');
    }
  }

  void _disposeController() {
    try {
      playerStateSubscription?.cancel();
      controller?.dispose();
    } catch (e) {
      debugPrint('خطأ في إغلاق المشغل: $e');
    } finally {
      controller = null;
      _isPrepared.value = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    _playerState.dispose();
    _isLoading.dispose();
    _isPrepared.dispose();
    _errorMessage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: widget.config?.decoration ??
              BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: widget.isMessageBySender
                    ? widget.outgoingChatBubbleConfig?.color
                    : widget.inComingChatBubbleConfig?.color,
              ),
          padding: widget.config?.padding ??
              const EdgeInsets.symmetric(horizontal: 8),
          margin: widget.config?.margin ??
              EdgeInsets.symmetric(
                horizontal: 8,
                vertical: widget.message.reaction.reactions.isNotEmpty ? 15 : 0,
              ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildPlayButton(),
                  _buildWaveform(),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.message.createdAt.getTimeFromDateTime.toString(),
                textAlign: widget.isMessageBySender ? TextAlign.end : TextAlign.start,
                style: _textTimeStyle ??
                    textTheme.bodyMedium!.copyWith(
                      color: Colors.grey,
                      fontSize: 14,
                    ),
              ),
            ],
          ),
        ),
        if (widget.message.reaction.reactions.isNotEmpty)
          ReactionWidget(
            isMessageBySender: widget.isMessageBySender,
            reaction: widget.message.reaction,
            messageReactionConfig: widget.messageReactionConfig,
          ),
      ],
    );
  }

  Widget _buildPlayButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLoading,
      builder: (context, loading, child) {
        if (loading) {
          return Container(
            padding: const EdgeInsets.all(8),
            child: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          );
        }

        return ValueListenableBuilder<PlayerState>(
          builder: (context, state, child) {
            return IconButton(
              onPressed: _playOrPause,
              icon: state.isPlaying
                  ? widget.config?.pauseIcon ??
                  const Icon(Icons.pause, color: Colors.white)
                  : widget.config?.playIcon ??
                  const Icon(Icons.play_arrow, color: Colors.white),
            );
          },
          valueListenable: _playerState,
        );
      },
    );
  }

  Widget _buildWaveform() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLoading,
      builder: (context, loading, child) {
        if (loading) {
          return Container(
            width: widget.screenWidth * 0.50,
            height: 60,
            alignment: Alignment.center,
            child: const Text(
              'جاري تحميل الصوت...',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        return ValueListenableBuilder<String?>(
          valueListenable: _errorMessage,
          builder: (context, error, child) {
            if (error != null) {
              return Container(
                width: widget.screenWidth * 0.50,
                height: 60,
                alignment: Alignment.center,
                child: GestureDetector(
                  onTap: _reinitializeAudio,
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh, color: Colors.white70, size: 20),
                      Text(
                        'اضغط للمحاولة مرة أخرى',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ValueListenableBuilder<bool>(
              valueListenable: _isPrepared,
              builder: (context, prepared, child) {
                if (!prepared || controller == null) {
                  return Container(
                    width: widget.screenWidth * 0.50,
                    height: 60,
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: _reinitializeAudio,
                      child: const Text(
                        'اضغط لتحضير الصوت',
                        style: TextStyle(
                          color: Colors.white70,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  );
                }

                return AudioFileWaveforms(
                  size: Size(widget.screenWidth * 0.50, 60),
                  playerController: controller!,
                  waveformType: WaveformType.fitWidth,
                  playerWaveStyle:
                  widget.config?.playerWaveStyle ?? playerWaveStyle,
                  padding: widget.config?.waveformPadding ??
                      const EdgeInsets.only(right: 10),
                  margin: widget.config?.waveformMargin,
                  animationCurve:
                  widget.config?.animationCurve ?? Curves.easeIn,
                  animationDuration: widget.config?.animationDuration ??
                      const Duration(milliseconds: 500),
                  enableSeekGesture: widget.config?.enableSeekGesture ?? true,
                );
              },
            );
          },
        );
      },
    );
  }

  void _playOrPause() async {
    assert(
    defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android,
    "Voice messages are only supported with android and iOS platform",
    );

    if (isLoading || _isDownloading) return;

    if (errorMessage != null) {
      await _reinitializeAudio();
      return;
    }

    if (!isPrepared || controller == null) {
      await _reinitializeAudio();
      return;
    }

    try {
      if (playerState.isPlaying) {
        await controller!.pausePlayer();
      } else {
        // If audio is completed, seek to zero before starting
        if (playerState == PlayerState.stopped) {
          await controller!.seekTo(0);
          debugPrint('تم الرجوع للبداية قبل التشغيل');
        }
        await controller!.startPlayer();
      }
    } catch (e) {
      _setError('خطأ في التشغيل: $e');
    }
  }

  TextStyle? get _textTimeStyle => widget.isMessageBySender
      ? widget.outgoingChatBubbleConfig?.textTimeStyle
      : widget.inComingChatBubbleConfig?.textTimeStyle;
}

/// Clean old temporary audio files (call this periodically in your app)
Future<void> cleanOldTempAudioFiles() async {
  try {
    final tempDir = await getTemporaryDirectory();
    final files = tempDir.listSync();

    for (final file in files) {
      if (file is File && file.path.contains('voice_')) {
        final stat = await file.stat();
        final daysSinceModified = DateTime.now().difference(stat.modified).inDays;

        if (daysSinceModified > 7) {
          await file.delete();
        }
      }
    }
  } catch (e) {
    debugPrint('خطأ في تنظيف الملفات المؤقتة: $e');
  }
}
