import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/auth_service.dart';
import 'design.dart';

/// Account screens: sign in, sign up with email code, password recovery.
/// Talks to the Lumino server at https://fascind.theluni.ru (see AuthService).
enum AuthStep { login, register, verify, forgot, reset }

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.auth,
    this.initialStep = AuthStep.login,
    this.onAuthenticated,
  });

  /// Shared client; the owner keeps the session token and disposes it.
  final AuthService auth;

  /// Which screen is shown first.
  final AuthStep initialStep;

  /// Called once the server has confirmed a session (login or email verified).
  final VoidCallback? onAuthenticated;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthService get _auth => widget.auth;
  late AuthStep _step = widget.initialStep;
  final List<AuthStep> _history = [];

  String _pendingEmail = '';
  bool _busy = false;
  String? _error;

  void _go(AuthStep step) {
    setState(() {
      _error = null;
      _history.add(_step);
      _step = step;
    });
  }

  void _reset(AuthStep step) {
    setState(() {
      _error = null;
      _history.clear();
      _step = step;
    });
  }

  void _back() {
    if (_history.isEmpty) return;
    setState(() {
      _error = null;
      _step = _history.removeLast();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _login(String username, String password) => _run(() async {
        await _auth.login(username: username, password: password);
        if (!mounted) return;
        widget.onAuthenticated?.call();
      });

  void _register({
    required String username,
    required String displayName,
    required String email,
    required String password,
    required String confirm,
  }) =>
      _run(() async {
        if (password != confirm) throw AuthException('Пароли не совпадают');
        await _auth.register(
          username: username,
          password: password,
          email: email,
          displayName: displayName,
        );
        _pendingEmail = email.trim().toLowerCase();
        if (mounted) _go(AuthStep.verify);
      });

  void _verify(String code) => _run(() async {
        await _auth.verify(email: _pendingEmail, code: code);
        if (!mounted) return;
        widget.onAuthenticated?.call();
      });

  void _resendCode() => _run(() async {
        await _auth.resend(email: _pendingEmail);
      });

  void _forgot(String email) => _run(() async {
        await _auth.forgot(email: email);
        _pendingEmail = email.trim().toLowerCase();
        if (mounted) _go(AuthStep.reset);
      });

  void _resetPassword(
          {required String code,
          required String password,
          required String confirm}) =>
      _run(() async {
        if (password != confirm) throw AuthException('Пароли не совпадают');
        await _auth.reset(
            email: _pendingEmail, code: code, newPassword: password);
        if (mounted) _reset(AuthStep.login);
      });

  @override
  Widget build(BuildContext context) {
    // TextField and other Material widgets need a Material ancestor. AuthGate
    // is the MaterialApp home and sits outside any Scaffold, so provide one here.
    return Material(
      color: kBg,
      type: MaterialType.canvas,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _AuthBackground(),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
              child: _AuthCard(
                onBack: _back,
                child: switch (_step) {
                  AuthStep.login => _LoginForm(
                      busy: _busy,
                      error: _error,
                      onSubmit: _login,
                      onRegister: () => _go(AuthStep.register),
                      onForgot: () => _go(AuthStep.forgot),
                    ),
                  AuthStep.register => _RegisterForm(
                      busy: _busy,
                      error: _error,
                      onSubmit: _register,
                    ),
                  AuthStep.verify => _VerifyForm(
                      email: _pendingEmail,
                      busy: _busy,
                      error: _error,
                      onSubmit: _verify,
                      onResend: _resendCode,
                    ),
                  AuthStep.forgot => _ForgotForm(
                      busy: _busy,
                      error: _error,
                      onSubmit: _forgot,
                    ),
                  AuthStep.reset => _ResetForm(
                      email: _pendingEmail,
                      busy: _busy,
                      error: _error,
                      onSubmit: _resetPassword,
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthBackground extends StatelessWidget {
  const _AuthBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: kBg),
        Positioned(
          left: 0,
          right: 0,
          bottom: -260,
          child: Center(
            child: Container(
              width: 900,
              height: 560,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x3A2E63B8), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({required this.child, required this.onBack});
  final Widget child;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 500;
    return SizedBox(
      width: math.min(440, width - 32),
      child: Container(
        padding:
            EdgeInsets.fromLTRB(compact ? 22 : 36, 22, compact ? 22 : 36, 30),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF0121216), Color(0xF40A0A0D)],
          ),
          border: Border.all(color: const Color(0x1AFFFFFF)),
          boxShadow: kPanelShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconAction(
                  icon: 'back',
                  onTap: onBack,
                  size: 30,
                  iconSize: 18,
                  tooltip: 'Назад'),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _AuthHeader extends StatelessWidget {
  const _AuthHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo.png', width: 24, height: 24),
            const SizedBox(width: 10),
            const Text('Lumino',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4)),
          ],
        ),
        const SizedBox(height: 18),
        Text(title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        Container(width: 36, height: 2, color: const Color(0x33FFFFFF)),
        const SizedBox(height: 26),
      ],
    );
  }
}

class _AuthFooter extends StatelessWidget {
  const _AuthFooter();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 22),
        Container(height: 1, color: const Color(0x14FFFFFF)),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            _FascindMark(),
            SizedBox(width: 8),
            Text('fascind ID',
                style: TextStyle(
                    fontSize: 13,
                    color: Color(0x8FFFFFFF),
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ],
    );
  }
}

class _FascindMark extends StatelessWidget {
  const _FascindMark();

  @override
  Widget build(BuildContext context) {
    Widget bar(double h) => Container(
          width: 3,
          height: h,
          decoration: BoxDecoration(
              color: const Color(0xFF6FA8E8),
              borderRadius: BorderRadius.circular(2)),
        );
    return SizedBox(
      width: 20,
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          bar(8),
          const SizedBox(width: 3),
          bar(16),
          const SizedBox(width: 3),
          bar(8)
        ],
      ),
    );
  }
}

class _AuthField extends StatefulWidget {
  const _AuthField({
    required this.controller,
    required this.icon,
    required this.hint,
    this.obscurable = false,
    this.keyboardType,
  });
  final TextEditingController controller;
  final String icon;
  final String hint;
  final bool obscurable;
  final TextInputType? keyboardType;

  @override
  State<_AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<_AuthField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Row(
        children: [
          LIcon(widget.icon, size: 18, color: const Color(0x8FFFFFFF)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: widget.controller,
              obscureText: widget.obscurable && _obscure,
              keyboardType: widget.keyboardType,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontSize: 14.5, color: Colors.white),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle:
                    const TextStyle(fontSize: 14.5, color: Color(0x8FFFFFFF)),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          if (widget.obscurable)
            TapArea(
              onTap: () => setState(() => _obscure = !_obscure),
              child: LIcon(_obscure ? 'eye' : 'eyeOff',
                  size: 18, color: const Color(0x8FFFFFFF)),
            ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.busy = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: PlayButton(
              label: label,
              icon: false,
              height: 46,
              onTap: busy ? null : onTap,
            ),
          ),
          if (busy)
            const Positioned(
              right: 18,
              child: IgnorePointer(
                child: SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF111111),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError({required this.text});
  final String? text;

  @override
  Widget build(BuildContext context) {
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text!,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A80)),
      ),
    );
  }
}

class _RegisterForm extends StatefulWidget {
  const _RegisterForm(
      {required this.busy, required this.error, required this.onSubmit});
  final bool busy;
  final String? error;
  final void Function({
    required String username,
    required String displayName,
    required String email,
    required String password,
    required String confirm,
  }) onSubmit;

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    for (final c in [_username, _name, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AuthHeader(title: 'Создать аккаунт'),
        _AuthField(
            controller: _username, icon: 'user', hint: 'Имя пользователя'),
        const SizedBox(height: 12),
        _AuthField(
            controller: _name,
            icon: 'user',
            hint: 'Отображаемое имя (необязательно)'),
        const SizedBox(height: 12),
        _AuthField(
          controller: _email,
          icon: 'mail',
          hint: 'Email',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _AuthField(
            controller: _password,
            icon: 'lock',
            hint: 'Пароль',
            obscurable: true),
        const SizedBox(height: 12),
        _AuthField(
            controller: _confirm,
            icon: 'lock',
            hint: 'Повторите пароль',
            obscurable: true),
        const SizedBox(height: 22),
        _AuthError(text: widget.error),
        _PrimaryButton(
          label: widget.busy ? 'Подождите…' : 'Зарегистрироваться',
          busy: widget.busy,
          onTap: () => widget.onSubmit(
            username: _username.text.trim(),
            displayName: _name.text.trim(),
            email: _email.text.trim(),
            password: _password.text,
            confirm: _confirm.text,
          ),
        ),
        const _AuthFooter(),
      ],
    );
  }
}

class _VerifyForm extends StatefulWidget {
  const _VerifyForm({
    required this.email,
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onResend,
  });
  final String email;
  final bool busy;
  final String? error;
  final void Function(String code) onSubmit;
  final VoidCallback onResend;

  @override
  State<_VerifyForm> createState() => _VerifyFormState();
}

class _VerifyFormState extends State<_VerifyForm> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AuthHeader(title: 'Подтверждение почты'),
        Text(
          'Код отправлен на ${widget.email}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: kMuted),
        ),
        const SizedBox(height: 16),
        _AuthField(
          controller: _code,
          icon: 'mail',
          hint: 'Код из письма',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 22),
        _AuthError(text: widget.error),
        _PrimaryButton(
          label: widget.busy ? 'Подождите…' : 'Подтвердить',
          busy: widget.busy,
          onTap: () => widget.onSubmit(_code.text.trim()),
        ),
        const SizedBox(height: 16),
        TapArea(
          onTap: widget.onResend,
          child: const Text('Отправить код ещё раз',
              style: TextStyle(fontSize: 13, color: kMuted)),
        ),
        const _AuthFooter(),
      ],
    );
  }
}

class _LoginForm extends StatefulWidget {
  const _LoginForm({
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onRegister,
    required this.onForgot,
  });
  final bool busy;
  final String? error;
  final void Function(String username, String password) onSubmit;
  final VoidCallback onRegister;
  final VoidCallback onForgot;

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _login = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AuthHeader(title: 'Вход в аккаунт'),
        _AuthField(controller: _login, icon: 'user', hint: 'Имя пользователя'),
        const SizedBox(height: 12),
        _AuthField(
            controller: _password,
            icon: 'lock',
            hint: 'Пароль',
            obscurable: true),
        const SizedBox(height: 22),
        _AuthError(text: widget.error),
        _PrimaryButton(
          label: widget.busy ? 'Подождите…' : 'Войти',
          busy: widget.busy,
          onTap: () => widget.onSubmit(_login.text.trim(), _password.text),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TapArea(
              onTap: widget.onForgot,
              child: const Text('Забыли пароль?',
                  style: TextStyle(fontSize: 13, color: kMuted)),
            ),
            TapArea(
              onTap: widget.onRegister,
              child: const Text('Ещё нет аккаунта?',
                  style: TextStyle(fontSize: 13, color: kMuted)),
            ),
          ],
        ),
        const _AuthFooter(),
      ],
    );
  }
}

class _ForgotForm extends StatefulWidget {
  const _ForgotForm(
      {required this.busy, required this.error, required this.onSubmit});
  final bool busy;
  final String? error;
  final void Function(String email) onSubmit;

  @override
  State<_ForgotForm> createState() => _ForgotFormState();
}

class _ForgotFormState extends State<_ForgotForm> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AuthHeader(title: 'Восстановление доступа'),
        _AuthField(
          controller: _email,
          icon: 'mail',
          hint: 'Email',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 22),
        _AuthError(text: widget.error),
        _PrimaryButton(
          label: widget.busy ? 'Подождите…' : 'Отправить',
          busy: widget.busy,
          onTap: () => widget.onSubmit(_email.text.trim()),
        ),
        const _AuthFooter(),
      ],
    );
  }
}

class _ResetForm extends StatefulWidget {
  const _ResetForm({
    required this.email,
    required this.busy,
    required this.error,
    required this.onSubmit,
  });
  final String email;
  final bool busy;
  final String? error;
  final void Function(
      {required String code,
      required String password,
      required String confirm}) onSubmit;

  @override
  State<_ResetForm> createState() => _ResetFormState();
}

class _ResetFormState extends State<_ResetForm> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AuthHeader(title: 'Новый пароль'),
        Text(
          'Код отправлен на ${widget.email}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: kMuted),
        ),
        const SizedBox(height: 16),
        _AuthField(
          controller: _code,
          icon: 'mail',
          hint: 'Код из письма',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        _AuthField(
            controller: _password,
            icon: 'lock',
            hint: 'Новый пароль',
            obscurable: true),
        const SizedBox(height: 12),
        _AuthField(
            controller: _confirm,
            icon: 'lock',
            hint: 'Повторите пароль',
            obscurable: true),
        const SizedBox(height: 22),
        _AuthError(text: widget.error),
        _PrimaryButton(
          label: widget.busy ? 'Подождите…' : 'Сохранить пароль',
          busy: widget.busy,
          onTap: () => widget.onSubmit(
            code: _code.text.trim(),
            password: _password.text,
            confirm: _confirm.text,
          ),
        ),
        const _AuthFooter(),
      ],
    );
  }
}
