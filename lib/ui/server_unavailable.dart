import 'package:flutter/material.dart';

import 'design.dart';

/// Shown over the whole app while the Lumino server does not answer. The app
/// keeps no copy of the account, so there is nothing to show without it.
class ServerUnavailablePage extends StatelessWidget {
  const ServerUnavailablePage({super.key, required this.onRetry, this.retrying = false});

  final VoidCallback onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo.png', height: 56),
                const SizedBox(height: 28),
                const Text(
                  'Сервер недоступен',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Музыка, плейлисты и настройки хранятся на сервере, поэтому без него '
                  'Lumino не работает. Проверьте интернет-соединение. Приложение подключится '
                  'само, как только сервер снова ответит.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 28),
                _RetryButton(onTap: retrying ? null : onRetry, busy: retrying),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap, required this.busy});

  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: kStroke),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kText),
                )
              else
                const Icon(Icons.refresh, size: 18, color: kText),
              const SizedBox(width: 10),
              Text(
                busy ? 'Подключаемся…' : 'Повторить',
                style: const TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
