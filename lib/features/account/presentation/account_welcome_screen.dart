import 'package:flutter/material.dart';
import 'package:smart_search_app/design_system/nexa_surfaces.dart';
import 'package:smart_search_app/design_system/nexa_theme.dart';
import 'package:smart_search_app/features/account/data/account_sync.dart';

class AccountWelcomeScreen extends StatefulWidget {
  const AccountWelcomeScreen({
    super.key,
    required this.accountSync,
    required this.onSignedIn,
    required this.onContinueWithoutAccount,
  });

  final AccountSync? accountSync;
  final Future<void> Function() onSignedIn;
  final Future<void> Function() onContinueWithoutAccount;

  @override
  State<AccountWelcomeScreen> createState() => _AccountWelcomeScreenState();
}

class _AccountWelcomeScreenState extends State<AccountWelcomeScreen> {
  bool _working = false;

  Future<void> _signIn(
      Future<Object?> Function(AccountSync account) action) async {
    final account = widget.accountSync;
    if (account == null) {
      _showMessage(
          'Account backup is not configured yet. Add your Firebase settings, then rebuild the app.');
      return;
    }
    setState(() => _working = true);
    try {
      final user = await action(account);
      if (user != null) await widget.onSignedIn();
    } catch (error) {
      _showMessage(AccountSync.signInErrorMessage(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.canvas,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const NexaAtmosphere(),
          SafeArea(
            child: Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 36,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: NexaBrand(),
                        ),
                        SizedBox(height: constraints.maxHeight < 700 ? 16 : 28),
                        if (constraints.maxHeight >= 700) ...[
                          const Center(child: NexaSignal(size: 150)),
                          const SizedBox(height: 24),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: NexaColors.glassQuiet,
                              borderRadius: BorderRadius.circular(20),
                              border:
                                  Border.all(color: const Color(0x18FFFFFF)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.lock_outline_rounded,
                                  color: NexaColors.cyan,
                                  size: 15,
                                ),
                                SizedBox(width: 7),
                                Text(
                                  'PRIVATE BY DESIGN',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Your day.\nA little easier.',
                          style: Theme.of(context)
                              .textTheme
                              .displaySmall
                              ?.copyWith(
                                color: Colors.white,
                                fontSize: 40,
                                height: 1.03,
                                letterSpacing: -1.6,
                              ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'One conversation for the things you do across your phone.',
                          style: TextStyle(
                            color: NexaColors.textSecondary,
                            fontSize: 16,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 26),
                        FilledButton.icon(
                          onPressed: _working
                              ? null
                              : () => _signIn(
                                    (account) => account.signInWithGoogle(),
                                  ),
                          icon: _working
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.g_mobiledata_rounded,
                                  size: 28),
                          label: const Text('Continue with Google'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(58),
                            backgroundColor: Colors.white,
                            foregroundColor: NexaColors.canvas,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _working
                              ? null
                              : () => _signIn(
                                    (account) => account.signInWithApple(),
                                  ),
                          icon: const Icon(Icons.apple_rounded),
                          label: const Text('Continue with Apple'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(58),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Color(0x42FFFFFF)),
                            backgroundColor: NexaColors.glassQuiet,
                          ),
                        ),
                        const SizedBox(height: 5),
                        TextButton(
                          onPressed:
                              _working ? null : widget.onContinueWithoutAccount,
                          child: const Text('Continue without an account'),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Contacts, searches, and documents stay on this device. Sign-in only restores your preferences.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: NexaColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )),
          ),
        ],
      ),
    );
  }
}
