import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_paths.dart';
import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'codex/codex_transport_factory.dart';
import '../remote/remote_claude.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex',
    icon: Icons.data_object_rounded,
    description: 'OpenAI’s coding agent',
    create: (context) {
      final transport = CodexTransportFactory.of(context);
      return CodexKernel(codex, transport, context: context);
    },
    catalog: CodexCatalog(
      transport: CodexTransportFactory.of(const KernelContext()),
    ),
  );

  /// The kernels on offer, in the order they are offered: the product's own
  /// first, so that a new agent runs on it. The codex product
  /// (`baocode-codex.exe`) runs on codex, BaoCode (the Claude Code one) on
  /// Claude Code; the other is there in both, for a user who wants it.
  static List<KernelDescriptor> _all = _byProduct();

  static List<KernelDescriptor> _byProduct() {
    final product = AppPaths.product(Platform.resolvedExecutable);
    final own = product == 'baocode-codex' ? codex : claudeCode;
    final other = product == 'baocode-codex' ? claudeCode : codex;
    return [own, other];
  }

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
