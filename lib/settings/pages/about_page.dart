import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../platform/app_links.dart';
import '../../platform/app_paths.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../update/version.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_header/about_dialog.dart' show aboutIconAsset;
import 'settings_widgets.dart';

/// Settings → About: what BaoCode is, which build this is, and where it
/// is made in the open: its repository (a star there helps others find
/// it), its releases (where the app is downloaded from), its changelog,
/// and where to tell of a problem.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  void _open(Uri url) => unawaited(openExternal('$url'));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final repository = AppLinks.repository;
    return SettingsPage(
      title: l10n.settingsSectionAbout,
      lead: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(
              aboutIconAsset,
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        // The product's name: BaoCode, or the codex one.
                        AppPaths.displayName(
                          Platform.environment,
                          executable: Platform.resolvedExecutable,
                        ),
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.aboutVersion(
                          currentAppVersion.marketing,
                          currentAppVersion.build,
                        ),
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 12,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallbacks,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(l10n.aboutTagline, style: SettingsText.lead),
                  const SizedBox(height: 6),
                  Text(
                    l10n.starPromptDetail,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: 'GitHub',
              description: l10n.aboutRepository(
                '${repository.host}${repository.path}',
              ),
              trailing: IdeButton(
                label: l10n.starPromptStar,
                icon: Codicons.star,
                onPressed: () => _open(repository),
              ),
            ),
            SettingsRow(
              label: l10n.aboutDownloads,
              description: l10n.aboutDownloadsDetail,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(AppLinks.releases),
              ),
            ),
            SettingsRow(
              label: l10n.aboutChangelog,
              description: l10n.aboutChangelogDetail,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(AppLinks.changelog),
              ),
            ),
            SettingsRow(
              label: l10n.aboutFeedback,
              description: l10n.aboutFeedbackDetail,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(AppLinks.issues),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
