import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

class KomgaSettingsPage extends StatefulWidget {
  const KomgaSettingsPage({super.key});

  @override
  State<KomgaSettingsPage> createState() => _KomgaSettingsPageState();
}

class _KomgaSettingsPageState extends State<KomgaSettingsPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverUrlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _apiKeyController;

  bool _testing = false;
  bool _saving = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController(text: komgaSetting.serverUrl.value);
    _usernameController = TextEditingController(text: komgaSetting.username.value);
    _passwordController = TextEditingController(text: komgaSetting.password.value);
    _apiKeyController = TextEditingController(text: komgaSetting.apiKey.value);
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('komgaSettings'.tr), centerTitle: true),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _serverUrlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: 'komgaServerUrl'.tr, hintText: 'https://komga.example.com', prefixIcon: const Icon(Icons.dns_outlined)),
              validator: _validateServerUrl,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              autocorrect: false,
              decoration: InputDecoration(labelText: 'userName'.tr, prefixIcon: const Icon(Icons.person_outline)),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'password'.tr,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(onPressed: () => setState(() => _obscurePassword = !_obscurePassword), icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('or'.tr)),
                  const Expanded(child: Divider()),
                ],
              ),
            ),
            TextFormField(
              controller: _apiKeyController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: 'komgaApiKey'.tr, helperText: 'komgaApiKeyHint'.tr, prefixIcon: const Icon(Icons.key_outlined)),
              validator: (_) => _validateCredentials(),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing || _saving ? null : _testConnection,
                    icon: _testing ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check),
                    label: Text('testConnection'.tr),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _testing || _saving ? null : _save,
                    icon: _saving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
                    label: Text('saveSetting'.tr),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _buildHint(Icons.cloud_sync_outlined, 'komgaConfigSyncHint'.tr),
            const SizedBox(height: 10),
            _buildHint(Icons.sync_alt_outlined, 'komgaProgressSyncHint'.tr),
          ],
        ),
      ),
    );
  }

  Widget _buildHint(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    );
  }

  String? _validateServerUrl(String? value) {
    final Uri? uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return 'invalidKomgaServerUrl'.tr;
    }
    return null;
  }

  String? _validateCredentials() {
    if (_apiKeyController.text.trim().isEmpty && _usernameController.text.trim().isEmpty) {
      return 'komgaCredentialsRequired'.tr;
    }
    return null;
  }

  KomgaClient _buildClient() {
    return KomgaClient(serverUrl: _serverUrlController.text, username: _usernameController.text.trim(), password: _passwordController.text, apiKey: _apiKeyController.text.trim());
  }

  Future<void> _testConnection() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    setState(() => _testing = true);
    try {
      await _buildClient().getLibraries();
      toast('komgaConnectionSuccess'.tr);
    } catch (e) {
      toast(KomgaClient.friendlyError(e), isShort: false);
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _save() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    setState(() => _saving = true);
    try {
      await komgaSetting.save(serverUrl: _serverUrlController.text, username: _usernameController.text, password: _passwordController.text, apiKey: _apiKeyController.text);
      if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
        await syncService.sync(types: CloudConfigTypeEnum.values);
      }
      toast('saveSuccess'.tr);
      Get.back(result: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}
