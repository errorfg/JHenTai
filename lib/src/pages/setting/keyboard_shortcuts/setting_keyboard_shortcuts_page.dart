import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/model/read_action.dart';
import 'package:jhentai/src/setting/keyboard_shortcut_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

class SettingKeyboardShortcutsPage extends StatefulWidget {
  const SettingKeyboardShortcutsPage({Key? key}) : super(key: key);

  @override
  State<SettingKeyboardShortcutsPage> createState() => _SettingKeyboardShortcutsPageState();
}

class _SettingKeyboardShortcutsPageState extends State<SettingKeyboardShortcutsPage> {
  ReadAction? _capturingAction;
  final FocusNode _captureFocusNode = FocusNode();

  /// Actions that are fixed and cannot be reassigned.
  static const Set<ReadAction> _fixedActions = {ReadAction.back};

  @override
  void dispose() {
    _captureFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _cancelCapture,
      behavior: HitTestBehavior.translucent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Text('keyboardShortcuts'.tr),
            actions: [
              TextButton(
                onPressed: _resetAll,
                child: Text('resetAll'.tr, style: const TextStyle(fontSize: 14)),
              ),
            ],
          ),
          body: Obx(
            () => Focus(
              focusNode: _captureFocusNode,
              onKeyEvent: _onCaptureKeyEvent,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: ReadAction.values.map(_buildActionTile).toList(),
              ).withListTileTheme(context),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tile builders
  // ---------------------------------------------------------------------------

  Widget _buildActionTile(ReadAction action) {
    if (_fixedActions.contains(action)) {
      return _buildFixedActionTile(action);
    }

    final bool isCapturing = _capturingAction == action;
    final ReadActionBinding? binding = keyboardShortcutSetting.bindingFor(action);

    return ListTile(
      title: Text(_actionLabel(action)),
      subtitle: isCapturing
          ? Text(
              'pressAnyKey'.tr,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            )
          : null,
      trailing: isCapturing
          ? _buildCapturingTrailing()
          : _buildBoundTrailing(binding, onClear: () => _clearBinding(action)),
      onTap: () {
        if (_capturingAction != null) {
          _cancelCapture();
        } else {
          _startCapture(action);
        }
      },
    );
  }

  Widget _buildFixedActionTile(ReadAction action) {
    return Tooltip(
      message: 'fixedKeyHint'.tr,
      child: ListTile(
        enabled: false,
        title: Text(
          _actionLabel(action),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.45)),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildKeyChip('Esc', dimmed: true),
            const SizedBox(width: 8),
            Icon(Icons.lock_outline, size: 18, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Trailing widgets
  // ---------------------------------------------------------------------------

  Widget _buildCapturingTrailing() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'pressAnyKey'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancelCapture,
          tooltip: 'cancel'.tr,
        ),
      ],
    );
  }

  Widget _buildBoundTrailing(ReadActionBinding? binding, {required VoidCallback onClear}) {
    final String label = binding == null ? 'unboundKey'.tr : _bindingLabel(binding);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildKeyChip(label, dimmed: binding == null),
        if (binding != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            onPressed: onClear,
            tooltip: 'clearKey'.tr,
          )
        else
          const SizedBox(width: 40),
      ],
    );
  }

  Widget _buildKeyChip(String label, {bool dimmed = false}) {
    return Container(
      constraints: const BoxConstraints(minWidth: 80),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: dimmed
            ? Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: dimmed ? Theme.of(context).colorScheme.onSurface.withOpacity(0.45) : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Capture logic
  // ---------------------------------------------------------------------------

  KeyEventResult _onCaptureKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _capturingAction == null) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelCapture();
      return KeyEventResult.handled;
    }

    _commitKeyboardCapture(event.logicalKey);
    return KeyEventResult.handled;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_capturingAction == null) {
      return;
    }

    final int button = event.buttons;
    if (button == kForwardMouseButton) {
      _commitMouseCapture(const ReadActionBinding.mouseButton4());
    } else if (button == kBackMouseButton) {
      _commitMouseCapture(const ReadActionBinding.mouseButton5());
    }
  }

  void _startCapture(ReadAction action) {
    setState(() {
      _capturingAction = action;
    });
    _captureFocusNode.requestFocus();
  }

  void _cancelCapture() {
    if (_capturingAction == null) {
      return;
    }
    setState(() {
      _capturingAction = null;
    });
  }

  Future<void> _commitKeyboardCapture(LogicalKeyboardKey key) async {
    final ReadAction? action = _capturingAction;
    if (action == null) {
      return;
    }

    setState(() {
      _capturingAction = null;
    });

    final ReadActionBinding newBinding = ReadActionBinding.keyboard(key.keyId);
    if (keyboardShortcutSetting.isBindingConflicting(newBinding, action)) {
      final ReadAction? conflicting = keyboardShortcutSetting.getActionForBinding(newBinding, action);
      toast(
        '${'keyConflict'.tr}: ${key.debugName} → ${conflicting != null ? _actionLabel(conflicting) : ''}',
        isShort: false,
      );
      return;
    }

    await keyboardShortcutSetting.bind(action, newBinding);
    toast('saveSuccess'.tr);
  }

  Future<void> _commitMouseCapture(ReadActionBinding mouseBinding) async {
    final ReadAction? action = _capturingAction;
    if (action == null) {
      return;
    }

    setState(() {
      _capturingAction = null;
    });

    if (keyboardShortcutSetting.isBindingConflicting(mouseBinding, action)) {
      final ReadAction? conflicting = keyboardShortcutSetting.getActionForBinding(mouseBinding, action);
      toast(
        '${'keyConflict'.tr}: ${_bindingLabel(mouseBinding)} → ${conflicting != null ? _actionLabel(conflicting) : ''}',
        isShort: false,
      );
      return;
    }

    await keyboardShortcutSetting.bind(action, mouseBinding);
    toast('saveSuccess'.tr);
  }

  Future<void> _clearBinding(ReadAction action) async {
    await keyboardShortcutSetting.bind(action, null);
  }

  Future<void> _resetAll() async {
    await keyboardShortcutSetting.resetAndSave();
    toast('resetSuccess'.tr);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _bindingLabel(ReadActionBinding binding) {
    if (binding.isKeyboard) {
      return binding.logicalKey?.debugName ?? '';
    }
    if (binding.isMouseButton4) {
      return 'mouseButton4Name'.tr;
    }
    return 'mouseButton5Name'.tr;
  }

  String _actionLabel(ReadAction action) {
    switch (action) {
      case ReadAction.toNext:
        return 'toNext'.tr;
      case ReadAction.toPrev:
        return 'toPrev'.tr;
      case ReadAction.toLeft:
        return 'toLeft'.tr;
      case ReadAction.toRight:
        return 'toRight'.tr;
      case ReadAction.back:
        return 'back'.tr;
      case ReadAction.toggleMenu:
        return 'toggleMenu'.tr;
      case ReadAction.toggleFirstPageAlone:
        return 'displayFirstPageAlone'.tr;
      case ReadAction.toggleFullScreen:
        return 'toggleFullScreen'.tr;
    }
  }
}

