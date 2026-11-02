import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Branded launch screen shown while the bundled model is installed and loaded.
class SplashScreen extends StatelessWidget {
  const SplashScreen({required this.status, super.key});

  final String status;

  static const Color _background = Color(0xFF0B0F0D);
  static const Color _mint = Color(0xFF82E6BD);
  static const Color _muted = Color(0xFF8FA69C);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _background,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.4),
              radius: 1.15,
              colors: [Color(0xFF173128), _background],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      'assets/branding/app_icon.png',
                      width: 104,
                      height: 104,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'JAI',
                    style: TextStyle(
                      color: _mint,
                      fontSize: 52,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Have a JAI',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Developed by MerjDev',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 13,
                      letterSpacing: 1.6,
                    ),
                  ),
                  const Spacer(flex: 2),
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(_mint),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Fully on-device. No internet needed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _muted.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
