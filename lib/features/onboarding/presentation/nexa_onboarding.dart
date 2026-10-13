import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_surfaces.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';

class NexaOnboardingScreen extends StatefulWidget {
  const NexaOnboardingScreen({
    super.key,
    required this.onComplete,
  });

  final Future<void> Function() onComplete;

  @override
  State<NexaOnboardingScreen> createState() => _NexaOnboardingScreenState();
}

class _NexaOnboardingScreenState extends State<NexaOnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  bool _finishing = false;

  static const _pages = <_OnboardingPageData>[
    _OnboardingPageData(
      eyebrow: 'MEET APEX AI',
      title: 'One place to ask and act.',
      description:
          'Find an app, understand a document, call someone, or search the web without breaking your flow.',
      icon: Icons.auto_awesome_rounded,
      examples: <_OnboardingExample>[
        _OnboardingExample(
            Icons.description_outlined, 'Find my economics notes'),
        _OnboardingExample(
            Icons.call_outlined, 'Call the Arpan I speak to most'),
        _OnboardingExample(
            Icons.travel_explore_rounded, 'Compare these flight details'),
      ],
    ),
    _OnboardingPageData(
      eyebrow: 'YOUR CONTEXT',
      title: 'Search what matters to you.',
      description:
          'Apex AI connects to sources only when you ask. Permissions are requested at the moment they become useful.',
      icon: Icons.center_focus_strong_rounded,
      examples: <_OnboardingExample>[
        _OnboardingExample(Icons.apps_rounded, 'Apps on this phone'),
        _OnboardingExample(
            Icons.people_alt_outlined, 'Contacts and conversations'),
        _OnboardingExample(
            Icons.folder_copy_outlined, 'Files and scanned documents'),
      ],
    ),
    _OnboardingPageData(
      eyebrow: 'CLEAR CONTROL',
      title: 'Nothing sensitive happens silently.',
      description:
          'Apex AI asks a focused follow-up when your request is unclear and confirms the exact recipient before acting.',
      icon: Icons.verified_user_outlined,
      examples: <_OnboardingExample>[
        _OnboardingExample(
            Icons.sms_outlined, 'Preview messages before sending'),
        _OnboardingExample(
            Icons.visibility_outlined, 'See which source was used'),
        _OnboardingExample(
            Icons.stop_circle_outlined, 'Stop voice or context instantly'),
      ],
    ),
    _OnboardingPageData(
      eyebrow: 'READY WHEN YOU ARE',
      title: 'Start from a tap or your voice.',
      description:
          'Open Apex AI normally, or use a shortcut to search your phone, scan a document, or begin speaking immediately.',
      icon: Icons.bolt_rounded,
      examples: <_OnboardingExample>[
        _OnboardingExample(Icons.mic_none_rounded, 'Ask Apex AI'),
        _OnboardingExample(Icons.search_rounded, 'Search this device'),
        _OnboardingExample(Icons.document_scanner_outlined, 'Scan a document'),
      ],
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_page < _pages.length - 1) {
      await _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onComplete();
    if (mounted) setState(() => _finishing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.canvas,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const NexaAtmosphere(quiet: true),
          SafeArea(
            child: Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                    child: Row(
                      children: [
                        const NexaBrand(compact: true),
                        const Spacer(),
                        TextButton(
                          onPressed: _finishing ? null : widget.onComplete,
                          child: const Text('Skip setup'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: _pages.length,
                      onPageChanged: (value) => setState(() => _page = value),
                      itemBuilder: (context, index) =>
                          _OnboardingPage(data: _pages[index]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              '${_page + 1} of ${_pages.length}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: NexaColors.textSecondary),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  minHeight: 3,
                                  value: (_page + 1) / _pages.length,
                                  backgroundColor: const Color(0x24FFFFFF),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _finishing ? null : _next,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(58),
                            backgroundColor: NexaColors.blue,
                            foregroundColor: Colors.white,
                          ),
                          child: _finishing
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(
                                  _page == _pages.length - 1
                                      ? 'Start using Apex AI'
                                      : 'Continue',
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({required this.data});

  final _OnboardingPageData data;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height - 270,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: NexaColors.cyan.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: NexaColors.cyan.withValues(alpha: 0.28),
                ),
              ),
              child: Icon(data.icon, color: NexaColors.cyan, size: 29),
            ),
            const SizedBox(height: 28),
            Text(
              data.eyebrow,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: NexaColors.cyan,
                    letterSpacing: 1.25,
                  ),
            ),
            const SizedBox(height: 10),
            Text(data.title, style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 14),
            Text(
              data.description,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: NexaColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 32),
            ...data.examples.map(
              (example) => Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: NexaColors.raised,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        example.icon,
                        size: 21,
                        color: NexaColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        example.label,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.icon,
    required this.examples,
  });

  final String eyebrow;
  final String title;
  final String description;
  final IconData icon;
  final List<_OnboardingExample> examples;
}

class _OnboardingExample {
  const _OnboardingExample(this.icon, this.label);

  final IconData icon;
  final String label;
}
