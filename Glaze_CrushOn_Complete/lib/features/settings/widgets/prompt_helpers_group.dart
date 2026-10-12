import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/prompt_helpers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../prompt_helpers_provider.dart';

/// The Prompt Helpers switches. Shown in the API settings (between Connection
/// and Context) and in the chat Tools "Prompt Helpers" sheet; both read and
/// write [promptHelpersProvider], so they always agree.
class PromptHelpersGroup extends ConsumerWidget {
  const PromptHelpersGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final helpers = ref.watch(promptHelpersProvider);
    final notifier = ref.read(promptHelpersProvider.notifier);

    void pickLength(PromptResponseLength length, bool on) {
      notifier.setLength(on ? length : PromptResponseLength.none);
    }

    return MenuGroup(
      compact: true,
      header: 'prompt_helpers_title'.tr(),
      description: 'prompt_helpers_desc'.tr(),
      items: [
        MenuSwitchItem(
          label: 'prompt_helper_formatting'.tr(),
          description: 'prompt_helper_formatting_desc'.tr(),
          value: helpers.formatting,
          onChanged: (v) => notifier.setFormatting(v),
        ),
        MenuSwitchItem(
          label: 'prompt_helper_user_name'.tr(),
          description: 'prompt_helper_user_name_desc'.tr(),
          value: helpers.userNameAccuracy,
          onChanged: (v) => notifier.setUserNameAccuracy(v),
        ),
        MenuSwitchItem(
          label: 'prompt_helper_user_agency'.tr(),
          description: 'prompt_helper_user_agency_desc'.tr(),
          value: helpers.userAgency,
          onChanged: (v) => notifier.setUserAgency(v),
        ),
        MenuSubHeader('prompt_helper_length_title'.tr()),
        MenuSwitchItem(
          label: 'prompt_helper_short'.tr(),
          description: 'prompt_helper_short_desc'.tr(),
          value: helpers.length == PromptResponseLength.short,
          onChanged: (v) => pickLength(PromptResponseLength.short, v),
        ),
        MenuSwitchItem(
          label: 'prompt_helper_medium'.tr(),
          description: 'prompt_helper_medium_desc'.tr(),
          value: helpers.length == PromptResponseLength.medium,
          onChanged: (v) => pickLength(PromptResponseLength.medium, v),
        ),
        MenuSwitchItem(
          label: 'prompt_helper_long'.tr(),
          description: 'prompt_helper_long_desc'.tr(),
          value: helpers.length == PromptResponseLength.long,
          onChanged: (v) => pickLength(PromptResponseLength.long, v),
        ),
      ],
    );
  }
}

/// The chat Tools "Prompt Helpers" panel: the same group as in the API
/// settings, in a sheet of its own so it is one tap away inside a character.
class PromptHelpersSheet extends StatelessWidget {
  const PromptHelpersSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SheetView(
      titleWidget: Text(
        'prompt_helpers_title'.tr(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurface,
        ),
      ),
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            0,
            MediaQuery.paddingOf(context).top + 12,
            0,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: const [PromptHelpersGroup()],
        ),
      ),
    );
  }
}
