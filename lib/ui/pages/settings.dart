import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../actions.dart';
import '../design.dart';
import '../importer_dialog.dart';

const List<int> eqFrequencies = [
  32,
  64,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000
];

String eqFreqLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}K' : '$hz';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.state,
    required this.onSignOut,
    required this.onCheckForUpdates,
  });
  final AppState state;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onCheckForUpdates;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _refreshingServer = false;
  bool _checkingForUpdates = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scope = ThemeScope.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 32, compact ? 14 : 24,
          compact ? 16 : 32, compact ? 24 : 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Row(children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: LIcon(
                      'gear',
                      size: 22,
                      color: scope.light
                          ? const Color(0xFF333337)
                          : const Color(0xFFE4E4E6),
                    ),
                  ),
                  SizedBox(width: compact ? 10 : 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                            color: scope.foreground,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Make Lumino feel like yours.',
                          style: TextStyle(
                            fontSize: 13.5,
                            color: scope.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
              Reveal(
                  index: 0,
                  child: _SetCard(
                    icon: 'spark',
                    title: 'Appearance',
                    subtitle: 'Choose how Lumino looks on your desktop.',
                    child: _ThemeGrid(state: state),
                  )),
              Reveal(
                  index: 1,
                  child: _SetCard(
                    icon: 'eye',
                    title: 'Artwork previews',
                    subtitle: 'Open cover artwork in fullscreen when clicked.',
                    trailing: SwitchPill(
                      value: state.settings.openArtwork,
                      onTap: () =>
                          state.setArtworkOpen(!state.settings.openArtwork),
                    ),
                    hasBody: false,
                    child: const SizedBox.shrink(),
                  )),
              Reveal(
                  index: 2,
                  child: _SetCard(
                    icon: 'eyeOff',
                    title: 'Fullscreen background blur',
                    subtitle: 'Blur the artwork behind the fullscreen player.',
                    trailing: SwitchPill(
                      value: state.settings.blurFullscreenArtwork,
                      onTap: () => state.setFullscreenArtworkBlur(
                          !state.settings.blurFullscreenArtwork),
                    ),
                    hasBody: false,
                    child: const SizedBox.shrink(),
                  )),
              Reveal(
                  index: 3,
                  child: _SetCard(
                    icon: 'imageOff',
                    title: 'Fullscreen background artwork',
                    subtitle: 'Show the cover behind the fullscreen player.',
                    trailing: SwitchPill(
                      value: state.settings.showFullscreenArtwork,
                      onTap: () => state.setFullscreenArtworkVisible(
                          !state.settings.showFullscreenArtwork),
                    ),
                    hasBody: false,
                    child: const SizedBox.shrink(),
                  )),
              if (Platform.isWindows)
                Reveal(
                    index: 4,
                    child: _SetCard(
                      icon: 'bolt',
                      title: 'Windows efficiency mode',
                      subtitle:
                          'Reduce power use while Lumino is minimized or hidden in the tray.',
                      trailing: SwitchPill(
                        value: state.settings.windowsEfficiencyMode,
                        onTap: () async {
                          await state.setWindowsEfficiencyMode(
                              !state.settings.windowsEfficiencyMode);
                        },
                      ),
                      hasBody: false,
                      child: const SizedBox.shrink(),
                    )),
              Reveal(
                  index: 5,
                  child: _SetCard(
                    icon: 'volume',
                    title: 'Streaming quality',
                    subtitle: 'Higher quality uses more data.',
                    child: _QualitySeg(state: state),
                  )),
              Reveal(index: 6, child: _EqCard(state: state)),
              Reveal(
                  index: 7,
                  child: _SetCard(
                    icon: 'bolt',
                    title: 'Server',
                    subtitle:
                        'Lumino streams audio through your own Lumino nodes.',
                    trailing: ChipButton(
                      label: 'Refresh',
                      ghost: true,
                      height: 30,
                      icon: _refreshingServer ? null : 'restore',
                      onTap: _refreshingServer
                          ? null
                          : () async {
                              setState(() => _refreshingServer = true);
                              try {
                                state.applyNodeState(await state.node.state());
                              } catch (_) {}
                              if (mounted) {
                                setState(() => _refreshingServer = false);
                              }
                            },
                    ),
                    child: _ServerList(state: state),
                  )),
              Reveal(
                  index: 8,
                  child: _SetCard(
                    icon: 'folderPlus',
                    title: 'Import music',
                    subtitle:
                        'Bring liked songs and playlists from Spotify, Yandex Music, YouTube Music and others.',
                    trailing: ChipButton(
                      label: 'Import…',
                      onTap: () => showImporter(context, state),
                    ),
                    hasBody: false,
                    child: const SizedBox.shrink(),
                  )),
              if (Platform.isWindows)
                Reveal(
                    index: 9,
                    child: _SetCard(
                      icon: 'restore',
                      title: 'Updates',
                      subtitle:
                          'Check GitHub for the latest Windows version and install it.',
                      trailing: ChipButton(
                        label: _checkingForUpdates ? 'Checking…' : 'Check now',
                        icon: _checkingForUpdates ? null : 'restore',
                        ghost: true,
                        height: 30,
                        onTap: _checkingForUpdates
                            ? null
                            : () async {
                                setState(() => _checkingForUpdates = true);
                                try {
                                  await widget.onCheckForUpdates();
                                } finally {
                                  if (mounted) {
                                    setState(() => _checkingForUpdates = false);
                                  }
                                }
                              },
                      ),
                      hasBody: false,
                      child: const SizedBox.shrink(),
                    )),
              Reveal(
                  index: 10,
                  child: _SetCard(
                    icon: 'user',
                    title: 'Account',
                    subtitle: 'Sign out of your Lumino account on this device.',
                    trailing: ChipButton(
                      label: 'Sign out',
                      icon: 'exit',
                      ghost: true,
                      onTap: () async {
                        final confirmed = await confirmDialog(
                          context,
                          title: 'Sign out?',
                          message:
                              'You can sign back in to access your library.',
                          confirmLabel: 'Sign out',
                        );
                        if (confirmed) await widget.onSignOut();
                      },
                    ),
                    child: const SizedBox.shrink(),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetCard extends StatelessWidget {
  const _SetCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    this.hasBody = true,
  });

  final String icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;
  final bool hasBody;

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 25,
              height: 25,
              child: LIcon(
                icon,
                size: 18,
                color: scope.foreground,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: scope.foreground,
                        )),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 13,
                            color: ThemeScope.of(context).mutedForeground,
                            height: 1.4)),
                  ]),
            ),
            if (trailing != null) ...[const SizedBox(width: 16), trailing!],
          ]),
          if (hasBody)
            Padding(
              padding: const EdgeInsets.only(top: 16, left: 51),
              child: child,
            ),
        ],
      ),
    );
  }
}

class _ThemeGrid extends StatelessWidget {
  const _ThemeGrid({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    const options = [
      (
        'dark',
        'Dark',
        [Color(0xFF17171B), Color(0xFF050506), Color(0xFF2A2A30)]
      ),
      (
        'light',
        'Light',
        [Color(0xFFF2F2F4), Color(0xFFFFFFFF), Color(0xFFD8D8DE)]
      ),
      (
        'black',
        'Black',
        [Color(0xFF0A0A0B), Color(0xFF000000), Color(0xFF1A1A1D)]
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: _ThemePreview(
              id: options[i].$1,
              label: options[i].$2,
              colors: options[i].$3,
              active: state.settings.theme == options[i].$1,
              onTap: () => state.setTheme(options[i].$1),
            ),
          ),
        ],
      ],
    );
  }
}

class _ThemePreview extends StatefulWidget {
  const _ThemePreview({
    required this.id,
    required this.label,
    required this.colors,
    required this.active,
    required this.onTap,
  });
  final String id;
  final String label;
  final List<Color> colors;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_ThemePreview> createState() => _ThemePreviewState();
}

class _ThemePreviewState extends State<_ThemePreview> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 114,
            decoration: BoxDecoration(
              color: widget.colors[0],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: widget.active
                    ? Colors.white
                    : (_hovered
                        ? const Color(0x40FFFFFF)
                        : const Color(0x14FFFFFF)),
                width: widget.active ? 1.6 : 1,
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Container(
                width: 26,
                decoration: BoxDecoration(
                  color: widget.colors[2],
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(children: [
                  Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: widget.colors[2],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.colors[1],
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: const Color(0x12FFFFFF)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 18,
                    decoration: BoxDecoration(
                      color: widget.colors[2],
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 9),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (widget.active) ...[
              LIcon('check',
                  size: 13, color: ThemeScope.of(context).foreground),
              const SizedBox(width: 5),
            ],
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
                color: widget.active
                    ? ThemeScope.of(context).foreground
                    : ThemeScope.of(context).mutedForeground,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _QualitySeg extends StatelessWidget {
  const _QualitySeg({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    const options = [
      ('low', 'Low', '128 kbps'),
      ('normal', 'Normal', '192 kbps'),
      ('high', 'High', '320 kbps'),
    ];
    return Row(children: [
      for (final option in options)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: HoverBuilder(
              builder: (context, hovered) => GestureDetector(
                onTap: () => state.setQuality(option.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 58,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: state.settings.quality == option.$1
                        ? (scope.light ? Colors.white : const Color(0x1FFFFFFF))
                        : (hovered
                            ? (scope.light
                                ? const Color(0x0D17181C)
                                : const Color(0x0FFFFFFF))
                            : Colors.transparent),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: state.settings.quality == option.$1
                          ? (scope.light
                              ? const Color(0xFF252834)
                              : const Color(0xB3FFFFFF))
                          : scope.stroke,
                      width: state.settings.quality == option.$1 ? 1.3 : 1,
                    ),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      option.$2,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: state.settings.quality == option.$1
                            ? (scope.light
                                ? const Color(0xFF252834)
                                : Colors.white)
                            : scope.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      option.$3,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scope.mutedForeground,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

class _ServerList extends StatelessWidget {
  const _ServerList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final nodes = state.nodeState.nodes;
    return Column(children: [
      for (final node in nodes)
        _serverRow(
          label: node.label,
          subtitle: node.active
              ? (state.nodeState.auto
                  ? 'Selected automatically'
                  : 'Selected manually')
              : '',
          active: state.nodeState.active == node.id,
          latency: node.ms,
          status: node.ok,
          onTap: () => state.setServerNode(node.id),
        ),
      const SizedBox(height: 4),
      _serverRow(
        label: 'Auto-switch',
        subtitle: 'Move to another node when this one stops responding.',
        active: state.nodeState.auto,
        latency: 0,
        status: null,
        trailing: SwitchPill(
          value: state.nodeState.auto,
          onTap: () => state.toggleNodeAuto(),
        ),
        onTap: () => state.toggleNodeAuto(),
      ),
    ]);
  }

  Widget _serverRow({
    required String label,
    required String subtitle,
    required bool active,
    required int latency,
    required bool? status,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return HoverBuilder(
      builder: (context, hovered) {
        final scope = ThemeScope.of(context);
        return GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? (scope.light
                      ? const Color(0x1017181C)
                      : const Color(0x1FFFFFFF))
                  : (hovered
                      ? (scope.light
                          ? const Color(0x0817181C)
                          : const Color(0x0FFFFFFF))
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: active ? scope.stroke : scope.stroke),
            ),
            child: Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: status == null
                      ? scope.mutedForeground
                      : (status
                          ? const Color(0xFF9A9A9E)
                          : const Color(0xFF77777B)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w500,
                            color: active ? scope.foreground : scope.foreground,
                          )),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle,
                            style: TextStyle(
                                fontSize: 12,
                                color: ThemeScope.of(context).mutedForeground)),
                      ],
                    ]),
              ),
              if (latency > 0)
                Text('$latency ms',
                    style:
                        TextStyle(fontSize: 12, color: scope.mutedForeground)),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing,
              ] else if (active) ...[
                const SizedBox(width: 10),
                LIcon('check', size: 14, color: scope.foreground),
              ],
            ]),
          ),
        );
      },
    );
  }
}

class _EqCard extends StatefulWidget {
  const _EqCard({required this.state});
  final AppState state;

  @override
  State<_EqCard> createState() => _EqCardState();
}

class _EqCardState extends State<_EqCard> {
  late List<double> _bands = List<double>.from(widget.state.settings.eq.bands);
  late List<double> _previousBands = List<double>.from(_bands);
  int _curveAnimation = 0;

  @override
  void didUpdateWidget(covariant _EqCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isDragging) {
      _bands = List<double>.from(widget.state.settings.eq.bands);
    }
  }

  bool _isDragging = false;

  void _applyPreset(EqPreset preset) {
    setState(() {
      _previousBands = List<double>.from(_bands);
      _bands = List<double>.from(preset.bands);
      _curveAnimation++;
    });
    widget.state.applyEqPreset(preset);
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      await widget.state.importEqPreset(text);
    } catch (_) {
      widget.state.showToast('That isn’t a Lumino preset file');
    }
  }

  Future<void> _export() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export EQ preset',
      fileName:
          '${safeFileName(widget.state.settings.eq.preset.isEmpty ? 'eq-preset' : widget.state.settings.eq.preset)}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    await File(path).writeAsString(widget.state.exportEqPreset());
    widget.state.showToast('Preset exported');
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final eq = state.settings.eq;
    final presets = allEqPresets(state);
    final scope = ThemeScope.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          LIcon('volume', size: 20, color: scope.foreground),
          const SizedBox(width: 13),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Equalizer',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scope.foreground)),
              const SizedBox(height: 4),
              Text(
                eq.enabled
                    ? '10 bands · ${eq.preset.isEmpty ? 'Custom' : eq.preset}'
                    : '10 bands · Off',
                style: TextStyle(
                    fontSize: 13,
                    color: ThemeScope.of(context).mutedForeground),
              ),
            ]),
          ),
          SwitchPill(
              value: eq.enabled, onTap: () => state.setEqEnabled(!eq.enabled)),
        ]),
        const SizedBox(height: 18),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: eq.enabled ? 1 : 0.45,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              height: 236,
              child: Stack(children: [
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(_curveAnimation),
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    builder: (context, progress, child) => CustomPaint(
                      painter: _EqCurvePainter(
                          List.generate(
                            _bands.length,
                            (index) =>
                                ui.lerpDouble(
                                  _previousBands[index],
                                  _bands[index],
                                  progress,
                                ) ??
                                _bands[index],
                          ),
                          color: scope.light
                              ? const Color(0xFF55555A)
                              : const Color(0xFFD2D2D6)),
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 10; i++)
                      Expanded(
                        child: _EqBand(
                          value: _bands[i],
                          label: eqFreqLabel(eqFrequencies[i]),
                          enabled: eq.enabled,
                          onChanged: (value) {
                            setState(() {
                              _isDragging = true;
                              _bands[i] = value;
                            });
                            state.setEqBand(i, value);
                            _isDragging = false;
                          },
                        ),
                      ),
                  ],
                ),
              ]),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in presets)
                  ChipButton(
                    label: preset.name,
                    height: 30,
                    fontSize: 12,
                    ghost: eq.preset != preset.name,
                    onTap: () => _applyPreset(preset),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChipButton(
                label: 'Reset',
                height: 32,
                fontSize: 12.5,
                ghost: true,
                onTap: () {
                  _applyPreset(builtInEqPresets.first);
                },
              ),
              ChipButton(
                label: 'Save preset',
                height: 32,
                fontSize: 12.5,
                ghost: true,
                onTap: () async {
                  final name = await showTextPrompt(context,
                      title: 'Save preset',
                      placeholder: 'My preset',
                      okLabel: 'Save',
                      maxLength: 24);
                  if (name != null) await state.saveCustomPreset(name);
                },
              ),
              ChipButton(
                  label: 'Import',
                  height: 32,
                  fontSize: 12.5,
                  ghost: true,
                  onTap: _import),
              ChipButton(
                  label: 'Export',
                  height: 32,
                  fontSize: 12.5,
                  ghost: true,
                  onTap: _export),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _EqBand extends StatelessWidget {
  const _EqBand({
    required this.value,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

  final double value;
  final String label;
  final bool enabled;
  final ValueChanged<double> onChanged;

  static const double thumb = 12;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: 16,
        child: Text(formatDb(value),
            style: TextStyle(
                fontSize: 10.5,
                color: ThemeScope.of(context).mutedForeground,
                fontFeatures: [ui.FontFeature.tabularFigures()])),
      ),
      const SizedBox(height: 4),
      Expanded(
        // The track height is measured here, so the drag maths and the thumb
        // use exactly the same box (before, a guessed "height - 42" was used and
        // the thumb was drawn upside down: +12 dB sat at the bottom).
        child: LayoutBuilder(builder: (context, constraints) {
          final usable = math.max(1.0, constraints.maxHeight - thumb);
          void update(Offset local) {
            if (!enabled) return;
            final t =
                ((local.dy - thumb / 2) / usable).clamp(0.0, 1.0).toDouble();
            onChanged(((1 - t) * 24 - 12).clamp(-12.0, 12.0).toDouble());
          }

          final thumbTop = (1 - (value + 12) / 24) * usable;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (details) => update(details.localPosition),
            onVerticalDragUpdate: (details) => update(details.localPosition),
            onTapDown: (details) => update(details.localPosition),
            onDoubleTap: () {
              if (enabled) onChanged(0);
            },
            child: MouseRegion(
              cursor: enabled
                  ? SystemMouseCursors.resizeUpDown
                  : SystemMouseCursors.basic,
              child: Stack(children: [
                Positioned(
                  top: thumb / 2,
                  bottom: thumb / 2,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: ThemeScope.of(context)
                            .foreground
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: thumbTop,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: thumb,
                      height: thumb,
                      decoration: BoxDecoration(
                        color: enabled
                            ? ThemeScope.of(context).foreground
                            : ThemeScope.of(context)
                                .foreground
                                .withValues(alpha: 0.50),
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 6,
                              offset: Offset(0, 2))
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 14,
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5,
                color: ThemeScope.of(context).mutedForeground,
                fontFeatures: [ui.FontFeature.tabularFigures()])),
      ),
    ]);
  }
}

class _EqCurvePainter extends CustomPainter {
  _EqCurvePainter(List<double> bands, {required this.color})
      : bands = List<double>.of(bands);
  final List<double> bands;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paintGrid = Paint()
      ..color = color.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = 26 + (size.height - 52) * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paintGrid);
    }
    const chartTop = 26.0; // 16 label + 4 gap + half a thumb
    final chartHeight =
        math.max(1.0, size.height - 26 - 26); // 6 gap + 14 label + half a thumb
    final points = <Offset>[];
    for (var i = 0; i < bands.length; i++) {
      final x = size.width * (i + 0.5) / bands.length;
      final y = chartTop + chartHeight * (1 - (bands[i] + 12) / 24);
      points.add(Offset(x, y));
    }
    if (points.isEmpty) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final cur = points[i];
      final midX = (prev.dx + cur.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, cur.dy, cur.dx, cur.dy);
    }
    final fill = Path.from(path)
      ..lineTo(points.last.dx, chartTop + chartHeight)
      ..lineTo(points.first.dx, chartTop + chartHeight)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, chartTop, size.width, chartHeight)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.56)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    if (oldDelegate.color != color) return true;
    if (oldDelegate.bands.length != bands.length) return true;
    for (var i = 0; i < bands.length; i++) {
      if (oldDelegate.bands[i] != bands[i]) return true;
    }
    return false;
  }
}
