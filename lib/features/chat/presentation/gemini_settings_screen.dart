import 'dart:async';

import 'package:flutter/material.dart';
import 'package:smart_search_app/features/chat/data/gemini_client.dart';
import 'package:smart_search_app/features/chat/data/gemini_settings_store.dart';
import 'package:url_launcher/url_launcher.dart';

class GeminiSettingsScreen extends StatefulWidget {
  const GeminiSettingsScreen(
      {super.key, required this.store, required this.gateway});
  final GeminiSettingsStore store;
  final GeminiGateway gateway;
  @override
  State<GeminiSettingsScreen> createState() => _GeminiSettingsScreenState();
}

class _GeminiSettingsScreenState extends State<GeminiSettingsScreen> {
  final _key = TextEditingController();
  String _model = GeminiSettings.defaultModel;
  bool _loading = true;
  bool _busy = false;
  bool _obscure = true;
  bool _saved = false;
  bool _loadFailed = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (mounted) await _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _status = null;
    });
    try {
      final saved = await widget.store.read();
      if (!mounted) return;
      _key.text = saved.apiKey;
      _model = GeminiSettings.models.containsKey(saved.model)
          ? saved.model
          : GeminiSettings.defaultModel;
      _saved = saved.configured;
    } catch (_) {
      _loadFailed = true;
      _status =
          'Secure storage is unavailable. Unlock your device and try again.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  GeminiSettings get _settings =>
      GeminiSettings(apiKey: _key.text.trim(), model: _model);

  Future<void> _run({required bool test}) async {
    if (_key.text.trim().isEmpty) {
      setState(() => _status = 'Paste your Google AI Studio API key first.');
      return;
    }
    if (RegExp(r'\s').hasMatch(_key.text.trim())) {
      setState(() =>
          _status = 'The API key must not contain spaces or line breaks.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      if (test) {
        await widget.gateway.testConnection(_settings);
        if (mounted) {
          setState(() => _status =
              'Key and model are accessible. Answer generation still depends on your project quota. Save to use these settings.');
        }
      } else {
        await widget.store.write(_settings);
        if (mounted) {
          setState(() {
            _saved = true;
            _status =
                'Saved securely on this device. You can now start a chat.';
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = error is GeminiException
            ? error.message
            : 'Could not save your key securely. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Remove Gemini key?'),
              content: const Text(
                  'Saved chats stay on this device. You will need to add a key again to send new messages. An answer already being generated may finish.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Remove'))
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.remove();
      if (!mounted) return;
      _key.clear();
      setState(() {
        _saved = false;
        _status = 'API key removed. Your chat history is unchanged.';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Could not remove the key. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openStudio() async {
    try {
      final opened = await launchUrl(
          Uri.parse('https://aistudio.google.com/apikey'),
          mode: LaunchMode.externalApplication);
      if (!opened) throw StateError('Unavailable');
    } catch (_) {
      if (mounted) {
        setState(() => _status =
            'Open aistudio.google.com/apikey in your browser to create a key.');
      }
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final disabled = _loading || _busy || _loadFailed;
    return Scaffold(
      appBar: AppBar(title: const Text('Gemini settings')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                          color: colors.primaryContainer.withValues(alpha: .45),
                          borderRadius: BorderRadius.circular(24)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.auto_awesome_rounded,
                                color: colors.primary, size: 30),
                            const SizedBox(height: 14),
                            Text('Your key. Your conversations.',
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 8),
                            const Text(
                                'Connect Google AI Studio to ask questions, learn a topic, or work through an idea. No Apex account is needed.',
                                style: TextStyle(height: 1.5)),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                                onPressed: _openStudio,
                                icon: const Icon(Icons.open_in_new_rounded,
                                    size: 18),
                                label: const Text('Get a key in AI Studio')),
                          ])),
                  const SizedBox(height: 26),
                  if (_loading) const LinearProgressIndicator(),
                  TextField(
                      controller: _key,
                      enabled: !disabled,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      autofillHints: const [],
                      decoration: InputDecoration(
                          labelText: 'Gemini API key',
                          hintText: 'Paste your API key',
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                              tooltip:
                                  _obscure ? 'Show API key' : 'Hide API key',
                              onPressed: disabled
                                  ? null
                                  : () => setState(() => _obscure = !_obscure),
                              icon: Icon(_obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined)),
                          border: const OutlineInputBorder()),
                      onChanged: (_) => setState(() => _status = null)),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                      initialValue: _model,
                      key: ValueKey(_model),
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'Chat model',
                          border: OutlineInputBorder()),
                      items: GeminiSettings.models.entries
                          .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: disabled
                          ? null
                          : (value) => setState(() {
                                _model = value!;
                                _status = null;
                              })),
                  const SizedBox(height: 12),
                  const Text(
                      'Flash-Lite is the economical default. Google controls free-tier availability and limits. If your project has billing enabled, usage may cost money. The app never switches models automatically.',
                      style: TextStyle(height: 1.5, fontSize: 13)),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                      onPressed: disabled ? null : () => _run(test: false),
                      icon: const Icon(Icons.lock_outline_rounded),
                      label:
                          Text(_busy ? 'Please wait…' : 'Save key and model')),
                  const SizedBox(height: 8),
                  OutlinedButton(
                      onPressed: disabled ? null : () => _run(test: true),
                      child: const Text('Test connection')),
                  const Text(
                      'Test checks access to the model without generating an answer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12)),
                  if (_saved)
                    TextButton(
                        onPressed: disabled ? null : _remove,
                        child: const Text('Remove saved key')),
                  if (_status != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(_status!,
                            key: const Key('gemini-settings-status'),
                            style:
                                TextStyle(color: colors.primary, height: 1.5))),
                  if (_loadFailed)
                    OutlinedButton(
                        onPressed: _load,
                        child: const Text('Retry secure storage')),
                  const Divider(height: 36),
                  const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.privacy_tip_outlined),
                      title: Text('Know what leaves your phone'),
                      subtitle: Text(
                          'Sending a message sends this conversation’s text to Google. Your key is stored securely on this device, not in the APK or your account backup. History is local and is lost if you uninstall or clear app data.')),
                  const SizedBox(height: 12),
                  const Text(
                      'Google may use unpaid-service inputs and outputs to improve its products. With “Use indexed documents” enabled in a chat, matching document excerpts and source titles are sent with your question. Turn it off to send only chat messages. Contacts and original files are not uploaded. This chat does not include live web search.',
                      style: TextStyle(height: 1.5, fontSize: 13)),
                ],
              ))),
    );
  }
}
