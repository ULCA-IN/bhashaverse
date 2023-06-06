// ignore_for_file: invalid_use_of_protected_member

import 'package:custom_rating_bar/custom_rating_bar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../animation/lottie_animation.dart';
import '../../common/widgets/common_app_bar.dart';
import '../../localization/localization_keys.dart';
import '../../models/feedback_type_model.dart';
import '../../utils/constants/app_constants.dart';
import '../../utils/remove_glow_effect.dart';
import '../../utils/screen_util/screen_util.dart';
import '../../utils/snackbar_utils.dart';
import '../../utils/string_helper.dart';
import '../../utils/theme/app_text_style.dart';
import '../../utils/theme/app_theme_provider.dart';
import 'controller/feedback_controller.dart';
import '../../common/widgets/custom_elevated_button.dart';
import '../../common/widgets/transliteration_hints.dart';
import 'widgets/rating_widget.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late final FeedbackController _feedbackController;

  @override
  void initState() {
    _feedbackController = Get.find();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.appTheme.backgroundColor,
      body: SafeArea(
        child: Obx(
          () => _feedbackController.isLoading.value
              ? LottieAnimation(
                  context: context,
                  lottieAsset: animationLoadingLine,
                  footerText: loading.tr)
              : Stack(
                  children: [
                    ScrollConfiguration(
                      behavior: RemoveScrollingGlowEffect(),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: AppEdgeInsets.instance
                              .symmetric(vertical: 8, horizontal: 22),
                          child: Column(
                            children: [
                              SizedBox(height: 16.toHeight),
                              CommonAppBar(
                                title: feedback.tr,
                                showLogo: false,
                                onBackPress: () => Get.back(),
                              ),
                              SizedBox(height: 60.toHeight),
                              _buildCommonFeedback(context),
                              SizedBox(height: 18.toHeight),
                              _buildTaskFeedback(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Align(
                        alignment: Alignment.bottomCenter,
                        child: _buildTransliterationHints()),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _buildSubmitButton(context),
    );
  }

  Column _buildCommonFeedback(BuildContext context) {
    return Column(
      children: [
        Text(
          _feedbackController.feedbackReqResponse['pipelineFeedback']
              ['commonFeedback'][0]['question'],
          textAlign: TextAlign.center,
          style: semibold22(context),
        ),
        SizedBox(height: 14.toHeight),
        RatingBar(
          filledIcon: Icons.star,
          emptyIcon: Icons.star_border,
          filledColor: context.appTheme.primaryColor,
          onRatingChanged: (value) {
            _feedbackController.mainRating.value = value;
            for (var task in _feedbackController.feedbackTypeModels.value) {
              task.value.taskRating.value = null;
            }
          },
          initialRating: 0,
          maxRating: 5,
          alignment: Alignment.center,
        ),
      ],
    );
  }

  Obx _buildTaskFeedback() {
    return Obx(
      () => Visibility(
        visible: _feedbackController.mainRating.value < 4 &&
            _feedbackController.mainRating.value != 0.0,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ..._feedbackController.feedbackTypeModels.value.map((taskFeedback) {
            List<dynamic> taskList =
                _feedbackController.computePayload?['pipelineTasks'];
            bool? isTaskAvailable = taskList.firstWhereOrNull((element) =>
                    element['taskType'] == taskFeedback.value.taskType) !=
                null;
            return isTaskAvailable
                ? Obx(
                    () => RatingWidget(
                      feedbackTypeModel: taskFeedback.value,
                      onRatingChanged: (value) =>
                          taskFeedback.value.taskRating.value = value,
                      onTextChanged: (v) => _onTextChanged(
                          taskFeedback.value.textController,
                          taskFeedback: taskFeedback.value),
                    ),
                  )
                : const SizedBox.shrink();
          })
        ]),
      ),
    );
  }

  Widget _buildSubmitButton(BuildContext context) {
    return Obx(
      () => !_feedbackController.isLoading.value
          ? SafeArea(
              child: Padding(
                padding: AppEdgeInsets.instance.all(16.0),
                child: CustomElevetedButton(
                  buttonText: submit.tr,
                  textStyle: semibold22(context).copyWith(fontSize: 18.toFont),
                  backgroundColor: context.appTheme.primaryColor,
                  borderRadius: 16,
                  onButtonTap: () {
                    if (_feedbackController.mainRating.value > 0) {
                      _feedbackController.mainRating.value = 0;
                      _feedbackController.submitFeedbackPayload();
                      Get.back();
                    } else {
                      showDefaultSnackbar(message: errorGiveRating.tr);
                    }
                  },
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildTransliterationHints() {
    return MediaQuery.of(context).viewInsets.bottom != 0 &&
            _feedbackController.transliterationHints.value.isNotEmpty
        ? Obx(
            () {
              return Container(
                color: context.appTheme.backgroundColor,
                width: double.infinity,
                child: TransliterationHints(
                    scrollController: ScrollController(),
                    transliterationHints:
                        _feedbackController.transliterationHints.value,
                    showScrollIcon: false,
                    isScrollArrowVisible: false,
                    onSelected: (hintText) {
                      for (var taskFeedback
                          in _feedbackController.feedbackTypeModels) {
                        if (taskFeedback.value.focusNode.hasFocus) {
                          replaceWordWithHint(
                              taskFeedback.value.textController, hintText);

                          replaceSuggestedTextInPayload(taskFeedback.value,
                              taskFeedback.value.textController);

                          _feedbackController.transliterationHints.clear();
                          return;
                        }
                      }

                      _feedbackController.transliterationHints.clear();
                    }),
              );
            },
          )
        : const SizedBox.shrink();
  }

  void _onTextChanged(
    TextEditingController controller, {
    FeedbackTypeModel? taskFeedback,
  }) {
    String languageCode = '';

    if (taskFeedback != null) {
      // get language code for transliteration
      Map<String, dynamic>? task = (_feedbackController
              .suggestedOutput?['pipelineResponse'] as List<dynamic>)
          .firstWhereOrNull((e) => e['taskType'] == taskFeedback.taskType);
      languageCode = getLanguageCodeFromPayload(task);

      // update suggestion payload
      replaceSuggestedTextInPayload(taskFeedback, controller);
    }

    // get transliteration
    if (controller.text.length > _feedbackController.oldSourceText.length) {
      if (_feedbackController.isTransliterationEnabled()) {
        int cursorPosition = controller.selection.base.offset;
        String sourceText = controller.text;
        if (sourceText.trim().isNotEmpty &&
            sourceText[cursorPosition - 1] != ' ') {
          getTransliterationHints(
              getWordFromCursorPosition(sourceText, cursorPosition),
              languageCode);
        } else if (sourceText.trim().isNotEmpty &&
            _feedbackController.transliterationHints.isNotEmpty) {
          String wordTOReplace = _feedbackController.transliterationHints.first;
          replaceWordWithHint(controller, wordTOReplace);
          _feedbackController.transliterationHints.clear();
          if (taskFeedback != null) {
            replaceSuggestedTextInPayload(taskFeedback, controller);
          }
        } else if (_feedbackController.transliterationHints.isNotEmpty) {
          _feedbackController.transliterationHints.clear();
        }
      } else if (_feedbackController.transliterationHints.isNotEmpty) {
        _feedbackController.transliterationHints.clear();
      }
    }
    _feedbackController.oldSourceText = controller.text;
  }

  void replaceSuggestedTextInPayload(
    FeedbackTypeModel taskFeedback,
    TextEditingController controller,
  ) {
    Map<String, dynamic>? task = (_feedbackController
            .suggestedOutput?['pipelineResponse'] as List<dynamic>)
        .firstWhereOrNull((e) => e['taskType'] == taskFeedback.taskType);

    switch (task?['taskType']) {
      case 'asr':
        task?['output'][0]['source'] = controller.text;
        break;
      case 'translation':
        task?['output'][0]['target'] = controller.text;
        break;
    }
  }

  String getLanguageCodeFromPayload(Map<String, dynamic>? task) {
    String languageCode = '';

    String languageType =
        task?['taskType'] == 'asr' ? 'sourceLanguage' : 'targetLanguage';
    languageCode =
        (_feedbackController.computePayload?['pipelineTasks'] as List<dynamic>)
                .firstWhereOrNull(
                    (e) => e['taskType'] == task?['taskType'])['config']
            ['language'][languageType];

    return languageCode;
  }

  void getTransliterationHints(String newText, String languageCode) {
    String wordToSend = newText.split(" ").last;
    if (wordToSend.isNotEmpty) {
      _feedbackController.getTransliterationOutput(wordToSend, languageCode);
    } else {
      _feedbackController.transliterationHints.clear();
    }
  }
}
