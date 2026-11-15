import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Přihlášení a registrace e-mailem a heslem (Supabase Auth).
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nickname = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _nickname.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final session = ref.read(sessionProvider.notifier);
    try {
      if (_register) {
        final nickname = _nickname.text.trim();
        await ref.read(settingsProvider.notifier).setGreetingName(nickname);
        final signedIn = await session.signUp(
          email: _email.text,
          password: _password.text,
          greetingName: nickname,
        );
        if (!signedIn) {
          setState(() {
            _register = false;
            _info = 'Účet je založen. Potvrďte ho odkazem v e-mailu a pak se přihlaste.';
          });
          return;
        }
      } else {
        await session.signIn(email: _email.text, password: _password.text);
      }
      if (mounted) context.go(Routes.home);
    } on AuthException catch (error) {
      setState(() => _error = _translate(error.message));
    } catch (_) {
      setState(
        () => _error =
            'Přihlášení se nepodařilo. Zkontrolujte připojení k internetu.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Nejdřív vyplňte svůj e-mail.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(sessionProvider.notifier).resetPassword(email);
      setState(
        () => _info = 'Poslali jsme vám e-mail s odkazem na nové heslo.',
      );
    } on AuthException catch (error) {
      setState(() => _error = _translate(error.message));
    } catch (_) {
      setState(() => _error = 'E-mail se nepodařilo odeslat.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithoutAccount() async {
    await ref.read(settingsProvider.notifier).setSkipAuth(true);
    if (mounted) context.go(Routes.home);
  }

  String _translate(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return 'Nesprávný e-mail nebo heslo.';
    }
    if (lower.contains('email not confirmed')) {
      return 'E-mail ještě není potvrzený. Klepněte na odkaz, který jsme vám poslali.';
    }
    if (lower.contains('already registered')) {
      return 'Tento e-mail už účet má. Přihlaste se.';
    }
    if (lower.contains('password should be')) {
      return 'Heslo je příliš krátké nebo slabé.';
    }
    if (lower.contains('rate limit')) {
      return 'Příliš mnoho pokusů. Zkuste to za chvíli.';
    }
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBackend = ref.watch(supabaseClientProvider) != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset(
                      'assets/images/logo_mark.png',
                      height: 150,
                      excludeFromSemantics: true,
                    ),
                    const Center(child: Wordmark(fontSize: 34)),
                    const SizedBox(height: 6),
                    Text(
                      'Dvě hlavy. Jedna dokonalá chuť.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (!hasBackend) ...[
                      const HkCard(
                        child: Text(
                          'Připojení k Supabase zatím není nastavené. Kuchařka '
                          'funguje i bez něj – recepty se ukládají do telefonu. '
                          'Účet a synchronizaci zapnete později v nabídce Více.',
                        ),
                      ),
                      const SizedBox(height: 20),
                      CopperButton(
                        label: 'Pokračovat bez účtu',
                        onPressed: _continueWithoutAccount,
                      ),
                    ] else ...[
                      Text(
                        _register ? 'Nový účet' : 'Přihlášení',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      if (_register) ...[
                        TextFormField(
                          controller: _nickname,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.words,
                          maxLength: 30,
                          decoration: const InputDecoration(
                            labelText: 'Přezdívka',
                            helperText:
                                'Jak vás má aplikace oslovovat, '
                                'např. „Ahoj Pájo“.',
                            prefixIcon: Icon(Icons.waving_hand_outlined),
                            counterText: '',
                          ),
                          validator: (value) => (value?.trim() ?? '').isEmpty
                              ? 'Vyplňte přezdívku.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'E-mail',
                          prefixIcon: Icon(Icons.mail_outline_rounded),
                        ),
                        validator: (value) {
                          final text = value?.trim() ?? '';
                          if (text.isEmpty) return 'Vyplňte e-mail.';
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                              .hasMatch(text)) {
                            return 'E-mail nemá správný tvar.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: [
                          _register
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Heslo',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: _obscure
                                ? 'Zobrazit heslo'
                                : 'Skrýt heslo',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (value) {
                          final text = value ?? '';
                          if (text.isEmpty) return 'Vyplňte heslo.';
                          if (_register && text.length < 8) {
                            return 'Heslo musí mít aspoň 8 znaků.';
                          }
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      ],
                      if (_info != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _info!,
                          style: const TextStyle(color: AppColors.success),
                        ),
                      ],
                      const SizedBox(height: 20),
                      CopperButton(
                        label: _register ? 'Vytvořit účet' : 'Přihlásit se',
                        busy: _busy,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _register = !_register;
                                _error = null;
                                _info = null;
                              }),
                        child: Text(
                          _register
                              ? 'Už účet mám – přihlásit se'
                              : 'Nemám účet – zaregistrovat se',
                        ),
                      ),
                      if (!_register)
                        TextButton(
                          onPressed: _busy ? null : _resetPassword,
                          child: const Text('Zapomenuté heslo'),
                        ),
                      TextButton(
                        onPressed: _busy ? null : _continueWithoutAccount,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                        ),
                        child: const Text('Pokračovat bez účtu'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
