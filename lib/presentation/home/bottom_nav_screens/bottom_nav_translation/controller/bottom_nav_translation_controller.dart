import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:mic_stream/mic_stream.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vibration/vibration.dart';

import '../../../../../common/controller/language_model_controller.dart';
import '../../../../../models/task_sequence_response_model.dart';
import '../../../../../enums/language_enum.dart';
import '../../../../../enums/mic_button_status.dart';
import '../../../../../localization/localization_keys.dart';
import '../../../../../services/dhruva_api_client.dart';
import '../../../../../services/socket_io_client.dart';
import '../../../../../services/translation_app_api_client.dart';
import '../../../../../utils/constants/api_constants.dart';
import '../../../../../utils/constants/app_constants.dart';
import '../../../../../utils/permission_handler.dart';
import '../../../../../utils/snackbar_utils.dart';
import '../../../../../utils/voice_recorder.dart';
import '../../../../../utils/waveform_style.dart';

class BottomNavTranslationController extends GetxController {
  late DHRUVAAPIClient _dhruvaapiClient;
  late TranslationAppAPIClient _translationAppAPIClient;
  late LanguageModelController _languageModelController;

  TextEditingController sourceLanTextController = TextEditingController();
  TextEditingController targetLangTextController = TextEditingController();

  final ScrollController transliterationHintsScrollController =
      ScrollController();

  RxBool isTranslateCompleted = false.obs;
  bool isMicPermissionGranted = false;
  RxBool isLoading = false.obs;
  RxString selectedSourceLanguageCode = ''.obs;
  RxString selectedTargetLanguageCode = ''.obs;
  dynamic ttsResponse;
  RxBool isRecordedViaMic = false.obs;
  RxBool isPlayingSource = false.obs;
  RxBool isPlayingTarget = false.obs;
  RxBool isKeyboardVisible = false.obs;
  String sourcePath = '';
  String targetPath = '';
  RxInt maxDuration = 0.obs,
      currentDuration = 0.obs,
      sourceTextCharLimit = 0.obs;
  File? ttsAudioFile;
  RxList transliterationWordHints = [].obs;
  String? transliterationModelToUse = '';
  String currentlyTypedWordForTransliteration = '';
  RxBool isScrolledTransliterationHints = false.obs;
  late SocketIOClient _socketIOClient;
  Rx<MicButtonStatus> micButtonStatus = Rx(MicButtonStatus.released);
  DateTime? recordingStartTime;
  String beepSoundPath = '';
  late File beepSoundFile;
  PlayerController _controller = PlayerController();
  late Directory appDirectory;

  final VoiceRecorder _voiceRecorder = VoiceRecorder();

  late final Box _hiveDBInstance;

  late PlayerController controller;

  StreamSubscription<Uint8List>? micStreamSubscription;

  int silenceSize = 20;

  late Worker streamingResponseListener, socketIOErrorListener;

  @override
  void onInit() {
    _dhruvaapiClient = Get.find();
    _socketIOClient = Get.find();
    _translationAppAPIClient = Get.find();
    _languageModelController = Get.find();
    _hiveDBInstance = Hive.box(hiveDBName);
    controller = PlayerController();
    setBeepSoundFile();

    controller.onCompletion.listen((event) {
      isPlayingSource.value = false;
      isPlayingTarget.value = false;
    });

    controller.onCurrentDurationChanged.listen((duration) {
      currentDuration.value = duration;
    });

    controller.onPlayerStateChanged.listen((_) {
      switch (controller.playerState) {
        case PlayerState.initialized:
          maxDuration.value = controller.maxDuration;
          break;
        case PlayerState.paused:
          isPlayingSource.value = false;
          isPlayingTarget.value = false;
          currentDuration.value = 0;
          break;
        case PlayerState.stopped:
          currentDuration.value = 0;
          break;
        default:
      }
    });
    transliterationHintsScrollController.addListener(() {
      isScrolledTransliterationHints.value = true;
    });
    super.onInit();
    // tried to use enum values instead of boolean for Socket IO status
    // but that doesn't worked
    streamingResponseListener =
        ever(_socketIOClient.socketResponseText, (socketResponseText) {
      sourceLanTextController.text = socketResponseText;
      if (!isRecordedViaMic.value) isRecordedViaMic.value = true;
      if (!_socketIOClient.isMicConnected.value) {
        streamingResponseListener.dispose();
      }
    }, condition: () => _socketIOClient.isMicConnected.value);

    socketIOErrorListener = ever(_socketIOClient.hasError, (isAborted) {
      if (isAborted) {
        micButtonStatus.value = MicButtonStatus.released;
        showDefaultSnackbar(message: somethingWentWrong.tr);
      }
    }, condition: !_socketIOClient.isConnected());
  }

  @override
  void onClose() async {
    streamingResponseListener.dispose();
    socketIOErrorListener.dispose();
    _socketIOClient.disconnect();
    sourceLanTextController.dispose();
    targetLangTextController.dispose();
    disposePlayer();
    deleteAudioFiles();
    super.onClose();
  }

  void getSourceTargetLangFromDB() {
    String? _selectedSourceLanguage =
        _hiveDBInstance.get(preferredSourceLanguage);

    if (_selectedSourceLanguage == null || _selectedSourceLanguage.isEmpty) {
      _selectedSourceLanguage = _hiveDBInstance.get(preferredAppLocale);
    }

    if (_languageModelController.sourceTargetLanguageMap.keys
        .toList()
        .contains(_selectedSourceLanguage)) {
      selectedSourceLanguageCode.value = _selectedSourceLanguage ?? '';
      if (isTransliterationEnabled()) {
        setModelForTransliteration();
      }
    }

    String? _selectedTargetLanguage =
        _hiveDBInstance.get(preferredTargetLanguage);
    if (_selectedTargetLanguage != null &&
        _selectedTargetLanguage.isNotEmpty &&
        _languageModelController.sourceTargetLanguageMap.keys
            .toList()
            .contains(_selectedTargetLanguage)) {
      selectedTargetLanguageCode.value = _selectedTargetLanguage;
    }
  }

  setBeepSoundFile() async {
    appDirectory = await getTemporaryDirectory();
    beepSoundPath = "${appDirectory.path}/mic_tap_sound.wav";
    beepSoundFile = File(beepSoundPath);
    if (!await beepSoundFile.exists()) {
      await beepSoundFile.writeAsBytes(
          (await rootBundle.load(micBeepSound)).buffer.asUint8List());
    }
  }

  void swapSourceAndTargetLanguage() {
    if (isSourceAndTargetLangSelected()) {
      if (_languageModelController.sourceTargetLanguageMap.keys
              .contains(selectedTargetLanguageCode.value) &&
          _languageModelController
                  .sourceTargetLanguageMap[selectedTargetLanguageCode.value] !=
              null &&
          _languageModelController
              .sourceTargetLanguageMap[selectedTargetLanguageCode.value]!
              .contains(selectedSourceLanguageCode.value)) {
        String tempSourceLanguage = selectedSourceLanguageCode.value;
        selectedSourceLanguageCode.value = selectedTargetLanguageCode.value;
        selectedTargetLanguageCode.value = tempSourceLanguage;
        resetAllValues();
      } else {
        showDefaultSnackbar(
            message:
                '${getSelectedTargetLanguageName()} - ${getSelectedSourceLanguageName()} ${translationNotPossible.tr}');
      }
    } else {
      showDefaultSnackbar(message: kErrorSelectSourceAndTargetScreen.tr);
    }
  }

  bool isSourceAndTargetLangSelected() =>
      selectedSourceLanguageCode.value.isNotEmpty &&
      selectedTargetLanguageCode.value.isNotEmpty;

  String getSelectedSourceLanguageName() {
    return APIConstants.getLanguageCodeOrName(
        value: selectedSourceLanguageCode.value,
        returnWhat: LanguageMap.languageNameInAppLanguage,
        lang_code_map: APIConstants.LANGUAGE_CODE_MAP);
  }

  String getSelectedTargetLanguageName() {
    return APIConstants.getLanguageCodeOrName(
        value: selectedTargetLanguageCode.value,
        returnWhat: LanguageMap.languageNameInAppLanguage,
        lang_code_map: APIConstants.LANGUAGE_CODE_MAP);
  }

  void startVoiceRecording() async {
    await PermissionHandler.requestPermissions().then((isPermissionGranted) {
      isMicPermissionGranted = isPermissionGranted;
    });
    if (isMicPermissionGranted) {
      // clear previous recording files and
      // update state
      resetAllValues();

      //if user quickly released tap than Socket continue emit the data
      //So need to check before starting mic streaming
      if (micButtonStatus.value == MicButtonStatus.pressed) {
        await playBeepSound();
        await vibrateDevice();
        // wait until beep sound finished
        await Future.delayed(const Duration(milliseconds: 600));

        recordingStartTime = DateTime.now();
        if (_hiveDBInstance.get(isStreamingPreferred)) {
          connectToSocket();

          _socketIOClient.socketEmit(
            emittingStatus: 'start',
            emittingData: [
              APIConstants.createSocketIOComputePayload(
                  srcLanguage: selectedSourceLanguageCode.value,
                  targetLanguage: selectedTargetLanguageCode.value,
                  preferredGender:
                      _hiveDBInstance.get(preferredVoiceAssistantGender))
            ],
            isDataToSend: true,
          );

          MicStream.microphone(
                  audioSource: AudioSource.DEFAULT,
                  sampleRate: 44100,
                  channelConfig: ChannelConfig.CHANNEL_IN_MONO,
                  audioFormat: AudioFormat.ENCODING_PCM_16BIT)
              .then((stream) {
            List<int> checkSilenceList = List.generate(silenceSize, (i) => 0);
            micStreamSubscription = stream?.listen((value) {
              double meanSquared = meanSquare(value.buffer.asInt8List());
              _socketIOClient.socketEmit(
                  emittingStatus: 'data',
                  emittingData: [
                    {
                      "audio": [
                        {"audioContent": value}
                      ]
                    },
                    {"response_depth": 1},
                    false,
                    false
                  ],
                  isDataToSend: true);

              if (meanSquared >= 0.3) {
                checkSilenceList.add(0);
              }
              if (meanSquared < 0.3) {
                checkSilenceList.add(1);

                if (checkSilenceList.length > silenceSize) {
                  checkSilenceList = checkSilenceList
                      .sublist(checkSilenceList.length - silenceSize);
                }
                int sumValue = checkSilenceList
                    .reduce((value, element) => value + element);
                if (sumValue == silenceSize) {
                  _socketIOClient.socketEmit(
                      emittingStatus: 'data',
                      emittingData: [
                        {
                          "audio": [
                            {"audioContent": value}
                          ]
                        },
                        {"response_depth": 2},
                        true,
                        false
                      ],
                      isDataToSend: true);
                  checkSilenceList.clear();
                }
              }
            });
          });
        } else {
          await _voiceRecorder.startRecordingVoice();
        }
      }
    } else {
      showDefaultSnackbar(message: errorMicPermission.tr);
    }
  }

  void stopVoiceRecordingAndGetResult() async {
    await playBeepSound();
    await vibrateDevice();

    if (DateTime.now().difference(recordingStartTime ?? DateTime.now()) <
            tapAndHoldMinDuration &&
        isMicPermissionGranted) {
      showDefaultSnackbar(message: tapAndHoldForRecording.tr);
      if (!_hiveDBInstance.get(isStreamingPreferred)) return;
    }

    recordingStartTime = null;

    if (_hiveDBInstance.get(isStreamingPreferred)) {
      micStreamSubscription?.cancel();
      if (_socketIOClient.isMicConnected.value) {
        _socketIOClient.socketEmit(
            emittingStatus: 'data',
            emittingData: [
              null,
              {"response_depth": 2},
              true,
              true
            ],
            isDataToSend: true);
        await Future.delayed(const Duration(seconds: 5));
      }
      _socketIOClient.disconnect();
    } else {
      if (await _voiceRecorder.isVoiceRecording()) {
        String? base64EncodedAudioContent =
            await _voiceRecorder.stopRecordingVoiceAndGetOutput();
        if (base64EncodedAudioContent == null ||
            base64EncodedAudioContent.isEmpty) {
          showDefaultSnackbar(message: errorInRecording.tr);
          return;
        } else {
          await getComputeResponse(
              isRecorded: true, base64Value: base64EncodedAudioContent);
        }
      }
    }
  }

  Future<void> getTransliterationOutput(String sourceText) async {
    currentlyTypedWordForTransliteration = sourceText;
    if (transliterationModelToUse == null ||
        transliterationModelToUse!.isEmpty) {
      clearTransliterationHints();
      return;
    }
    var transliterationPayloadToSend = {};
    transliterationPayloadToSend['input'] = [
      {'source': sourceText}
    ];

    transliterationPayloadToSend['modelId'] = transliterationModelToUse;
    transliterationPayloadToSend['task'] = 'transliteration';
    transliterationPayloadToSend['userId'] = null;

    var response = await _translationAppAPIClient.sendTransliterationRequest(
        transliterationPayload: transliterationPayloadToSend);

    response?.when(
      success: (data) async {
        if (currentlyTypedWordForTransliteration ==
            data['output'][0]['source']) {
          transliterationWordHints.value = data['output'][0]['target'];
          if (!transliterationWordHints
              .contains(currentlyTypedWordForTransliteration)) {
            transliterationWordHints.add(currentlyTypedWordForTransliteration);
          }
        }
      },
      failure: (error) {
        showDefaultSnackbar(
            message: error.message ?? APIConstants.kErrorMessageGenericError);
      },
    );
  }

  Future<void> getComputeResponse({
    required bool isRecorded,
    String? base64Value,
    String? sourceText,
  }) async {
    isLoading.value = true;
    String asrServiceId = '';
    String translationServiceId = '';
    String ttsServiceId = '';
    asrServiceId = getTaskTypeServiceID(
            _languageModelController.taskSequenceResponse,
            'asr',
            selectedSourceLanguageCode.value) ??
        '';
    translationServiceId = getTaskTypeServiceID(
            _languageModelController.taskSequenceResponse,
            'asr',
            selectedSourceLanguageCode.value) ??
        '';
    ttsServiceId = getTaskTypeServiceID(
            _languageModelController.taskSequenceResponse,
            'asr',
            selectedSourceLanguageCode.value) ??
        '';

    var asrPayloadToSend = APIConstants.createRESTComputePayload(
        srcLanguage: selectedSourceLanguageCode.value,
        targetLanguage: selectedTargetLanguageCode.value,
        isRecorded: isRecorded,
        inputData: isRecorded ? base64Value! : sourceLanTextController.text,
        audioFormat: Platform.isIOS ? 'flac' : 'wav',
        asrServiceID: asrServiceId,
        translationServiceID: translationServiceId,
        ttsServiceID: ttsServiceId,
        preferredGender: _hiveDBInstance.get(preferredVoiceAssistantGender));

    var response = await _dhruvaapiClient.sendComputeRequest(
        baseUrl: _languageModelController
            .taskSequenceResponse.pipelineInferenceAPIEndPoint?.callbackUrl,
        authorizationKey: _languageModelController.taskSequenceResponse
            .pipelineInferenceAPIEndPoint?.inferenceApiKey?.name,
        authorizationValue: _languageModelController.taskSequenceResponse
            .pipelineInferenceAPIEndPoint?.inferenceApiKey?.value,
        computePayload: asrPayloadToSend);

    response.when(
      success: (taskResponse) async {
        if (isRecorded) {
          sourceLanTextController.text = taskResponse.pipelineResponse
                  ?.firstWhere((element) => element.taskType == 'asr')
                  .output
                  ?.first
                  .source ??
              '';
        }
        String outputTargetText = taskResponse.pipelineResponse
                ?.firstWhere((element) => element.taskType == 'translation')
                .output
                ?.first
                .target ??
            '';
        if (outputTargetText.isEmpty) {
          isLoading.value = false;
          showDefaultSnackbar(message: responseNotReceived.tr);
          return;
        }
        targetLangTextController.text = outputTargetText;
        ttsResponse = taskResponse.pipelineResponse
            ?.firstWhere((element) => element.taskType == 'tts')
            .audio[0]['audioContent'];
        isRecordedViaMic.value = isRecorded;
        isTranslateCompleted.value = true;
        isLoading.value = false;
      },
      failure: (error) {
        isLoading.value = false;
        showDefaultSnackbar(
            message: error.message ?? APIConstants.kErrorMessageGenericError);
      },
    );
  }

  String? getTaskTypeServiceID(TaskSequenceResponse sequenceResponse,
      String taskType, String sourceLanguageCode,
      [String? targetLanguageCode]) {
    List<Config>? configs = sequenceResponse.pipelineResponseConfig
        ?.firstWhere((element) => element.taskType == taskType)
        .config;
    for (var config in configs!) {
      if (config.language?.sourceLanguage == sourceLanguageCode) {
        // sends translation service id
        if (targetLanguageCode != null) {
          if (config.language?.targetLanguage == targetLanguageCode) {
            return config.serviceId;
          } else {
            return '';
          }
        } else
          return config.serviceId; // sends ASR, TTS service id
      }
    }
    return '';
  }

  void playTTSOutput(bool isPlayingForTarget) async {
    if (isPlayingForTarget ||
        _hiveDBInstance.get(isStreamingPreferred) && isRecordedViaMic.value) {
      if (ttsResponse != null) {
        Uint8List? fileAsBytes = base64Decode(ttsResponse);
        Directory appDocDir = await getApplicationDocumentsDirectory();
        targetPath =
            '${appDocDir.path}/$defaultTTSPlayName${DateTime.now().millisecondsSinceEpoch}.wav';
        ttsAudioFile = File(targetPath);
        if (ttsAudioFile != null && !await ttsAudioFile!.exists()) {
          await ttsAudioFile?.writeAsBytes(fileAsBytes);
        }

        isPlayingTarget.value = isPlayingForTarget;
        isPlayingSource.value =
            _hiveDBInstance.get(isStreamingPreferred) && !isPlayingForTarget;
        await prepareWaveforms(targetPath,
            isForTargeLanguage: isPlayingForTarget && isRecordedViaMic.value);
      } else {
        showDefaultSnackbar(message: noVoiceAssistantAvailable.tr);
      }
    } else {
      String? recordedAudioFilePath = _voiceRecorder.getAudioFilePath();
      if (recordedAudioFilePath != null && recordedAudioFilePath.isNotEmpty) {
        sourcePath = _voiceRecorder.getAudioFilePath()!;
        isPlayingSource.value = true;
        await prepareWaveforms(sourcePath, isForTargeLanguage: false);
        isPlayingTarget.value = false;
      }
    }
  }

  void setModelForTransliteration() {
    transliterationModelToUse =
        _languageModelController.getAvailableTransliterationModelsForLanguage(
            selectedSourceLanguageCode.value);
  }

  void clearTransliterationHints() {
    transliterationWordHints.clear();
    currentlyTypedWordForTransliteration = '';
  }

  void cancelPreviousTransliterationRequest() {
    _translationAppAPIClient.transliterationAPIcancelToken.cancel();
    _translationAppAPIClient.transliterationAPIcancelToken = CancelToken();
  }

  void resetAllValues() async {
    sourceLanTextController.clear();
    targetLangTextController.clear();
    isTranslateCompleted.value = false;
    isRecordedViaMic.value = false;
    await deleteAudioFiles();
    maxDuration.value = 0;
    currentDuration.value = 0;
    sourcePath = '';
    await stopPlayer();
    sourcePath = '';
    targetPath = '';
    if (isTransliterationEnabled()) {
      setModelForTransliteration();
      clearTransliterationHints();
    }
  }

  Future<void> prepareWaveforms(
    String filePath, {
    required bool isForTargeLanguage,
  }) async {
    if (controller.playerState == PlayerState.playing ||
        controller.playerState == PlayerState.paused) {
      controller.stopPlayer();
    }
    await controller.preparePlayer(
        path: filePath,
        noOfSamples: WaveformStyle.getDefaultPlayerStyle(
                isRecordedAudio: !isForTargeLanguage)
            .getSamplesForWidth(WaveformStyle.getDefaultWidth));
    maxDuration.value = controller.maxDuration;
    startOrStopPlayer();
  }

  void startOrStopPlayer() async {
    controller.playerState.isPlaying
        ? await controller.pausePlayer()
        : await controller.startPlayer(
            finishMode: FinishMode.pause,
          );
  }

  disposePlayer() async {
    await stopPlayer();
    controller.dispose();
  }

  Future<void> stopPlayer() async {
    if (controller.playerState.isPlaying) {
      await controller.stopPlayer();
    }
    isPlayingTarget.value = false;
    isPlayingSource.value = false;
  }

  Future<void> deleteAudioFiles({bool deleteRecordedFile = true}) async {
    if (deleteRecordedFile) _voiceRecorder.deleteRecordedFile();
    if (ttsAudioFile != null && !await ttsAudioFile!.exists()) {
      await ttsAudioFile?.delete();
    }
    ttsResponse = null;
  }

  bool isTransliterationEnabled() {
    return _hiveDBInstance.get(enableTransliteration, defaultValue: true);
  }

  void connectToSocket() {
    if (_socketIOClient.isConnected()) {
      _socketIOClient.disconnect();
    }
    _socketIOClient.socketConnect();
  }

  double meanSquare(Int8List value) {
    var sqrValue = 0;
    for (int indValue in value) {
      sqrValue = indValue * indValue;
    }
    return (sqrValue / value.length) * 1000;
  }

  Future<void> vibrateDevice() async {
    await Vibration.cancel();
    if (await Vibration.hasVibrator() ?? false) {
      if (await Vibration.hasCustomVibrationsSupport() ?? false) {
        await Vibration.vibrate(duration: 130);
      } else {
        await Vibration.vibrate();
      }
    }
  }

  Future<void> playBeepSound() async {
    if (_controller.playerState == PlayerState.playing ||
        _controller.playerState == PlayerState.paused) {
      await _controller.stopPlayer();
    }
    await _controller.preparePlayer(
      path: beepSoundFile.path,
      shouldExtractWaveform: false,
    );
    await _controller.startPlayer(finishMode: FinishMode.pause);
  }
}
