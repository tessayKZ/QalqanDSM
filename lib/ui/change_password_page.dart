import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/matrix_auth.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _old = TextEditingController();
  final _new1 = TextEditingController();
  final _new2 = TextEditingController();

  bool _busy = false;
  String? _error;

  bool _showOld = false;
  bool _showNew1 = false;
  bool _showNew2 = false;
  bool _logoutOthers = false;

  double _strengthPct = 0;
  String _strengthLabel = 'Too weak';
  Color _strengthColor = Colors.red;

  static const int _minLen = 8;
  bool _rLen = false;
  bool _rCase = false;
  bool _rDigit = false;
  bool _rSpecial = false;

  @override
  void initState() {
    super.initState();
    _new1.addListener(() => _recheck(_new1.text));
    _new2.addListener(() => setState(() {}));
  }

  void _recheck(String pw) {
    final hasLower = RegExp(r'[a-z]');
    final hasUpper = RegExp(r'[A-Z]');
    final hasDigit = RegExp(r'\d');

    final hasSpecial = RegExp(r'[^A-Za-z0-9\s]');

    final rLen = pw.length >= _minLen;
    final rCase = hasLower.hasMatch(pw) && hasUpper.hasMatch(pw);
    final rDigit = hasDigit.hasMatch(pw);
    final rSpecial = hasSpecial.hasMatch(pw);

    // score 0..5
    int score = 0;
    if (rLen) score++;
    if (pw.length >= 12) score++;
    if (rCase) score++;
    if (rDigit) score++;
    if (rSpecial) score++;

    double pct = (score / 5).clamp(0, 1).toDouble();
    String label;
    Color color;
    if (score <= 1) {
      label = 'Weak';
      color = Colors.red;
    } else if (score == 2) {
      label = 'Fair';
      color = Colors.orange;
    } else if (score == 3) {
      label = 'Good';
      color = Colors.amber[800]!;
    } else {
      label = 'Strong';
      color = Colors.green;
    }

    setState(() {
      _rLen = rLen;
      _rCase = rCase;
      _rDigit = rDigit;
      _rSpecial = rSpecial;

      _strengthPct = pct;
      _strengthLabel = label;
      _strengthColor = color;
      _error = null;
    });
  }

  bool _meetsBaseline() => _rLen && _rDigit && _rSpecial;

  Future<void> _submit() async {
    final oldP = _old.text.trim();
    final n1 = _new1.text.trim();
    final n2 = _new2.text.trim();

    if (oldP.isEmpty || n1.isEmpty || n2.isEmpty) {
      setState(() => _error = 'Fill in all fields');
      return;
    }
    if (n1 != n2) {
      setState(() => _error = "New passwords don't match");
      return;
    }
    if (!_meetsBaseline()) {
      setState(() => _error = 'Password must meet the requirements below');
      return;
    }

    setState(() { _busy = true; _error = null; });

    final ok = await AuthService.changePassword(
      oldPassword: oldP,
      newPassword: n1,
      logoutOtherDevices: _logoutOthers,
    );

    if (!mounted) return;
    setState(() => _busy = false);

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed')),
      );
      Navigator.of(context).pop();
    } else {
      setState(() => _error = 'Failed to change password');
    }
  }

  @override
  void dispose() {
    _old.dispose();
    _new1.dispose();
    _new2.dispose();
    super.dispose();
  }

  Widget _reqItem(String text, bool ok) {
    return Row(
      children: [
        Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18, color: ok ? Colors.green : Colors.grey),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }

  InputDecoration _dec(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon != null ? Icon(icon) : null,
      filled: true,
      fillColor: Colors.white.withOpacity(0.9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Change password'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [

          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/background.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),

          Container(color: Colors.black.withOpacity(0.25)),
          // Content
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: size.width < 600 ? size.width : 520,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.80),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_reset, size: 48, color: Color(0xFF6A11CB)),
                          const SizedBox(height: 10),
                          Text(
                            'Update your password',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 22),

                          TextField(
                            controller: _old,
                            obscureText: !_showOld,
                            decoration: _dec('Current password', icon: Icons.lock_outline).copyWith(
                              suffixIcon: IconButton(
                                icon: Icon(_showOld ? Icons.visibility_off : Icons.visibility),
                                onPressed: () => setState(() => _showOld = !_showOld),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          TextField(
                            controller: _new1,
                            obscureText: !_showNew1,
                            onChanged: _recheck,
                            decoration: _dec('New password', icon: Icons.lock).copyWith(
                              suffixIcon: IconButton(
                                icon: Icon(_showNew1 ? Icons.visibility_off : Icons.visibility),
                                onPressed: () => setState(() => _showNew1 = !_showNew1),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),

                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: _strengthPct,
                                    minHeight: 8,
                                    backgroundColor: Colors.grey.shade300,
                                    valueColor: AlwaysStoppedAnimation(_strengthColor),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                _strengthLabel,
                                style: TextStyle(
                                  color: _strengthColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          TextField(
                            controller: _new2,
                            obscureText: !_showNew2,
                            onChanged: (_) => setState(() {}),
                            decoration: _dec('Repeat new password', icon: Icons.lock).copyWith(
                              suffixIcon: IconButton(
                                icon: Icon(_showNew2 ? Icons.visibility_off : Icons.visibility),
                                onPressed: () => setState(() => _showNew2 = !_showNew2),
                              ),
                            ),
                          ),
                          if (_new2.text.isNotEmpty && _new2.text != _new1.text) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: const [
                                Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
                                SizedBox(width: 6),
                                Expanded(child: Text('Passwords do not match', style: TextStyle(color: Colors.orange))),
                              ],
                            ),
                          ],

                          const SizedBox(height: 12),

                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Password must include:',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _reqItem('At least $_minLen characters', _rLen),
                          _reqItem('Uppercase and lowercase letters', _rCase),
                          _reqItem('At least one number', _rDigit),
                          _reqItem('At least one special character', _rSpecial),

                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Icon(Icons.error_outline, color: Colors.red),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ],

                          const SizedBox(height: 8),

                          SwitchListTile.adaptive(
                            value: _logoutOthers,
                            onChanged: (v) => setState(() => _logoutOthers = v),
                            title: const Text('Log out on other devices'),
                            contentPadding: EdgeInsets.zero,
                          ),

                          const SizedBox(height: 6),

                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _busy ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6A11CB),
                                foregroundColor: Colors.white,
                                elevation: 6,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              child: _busy
                                  ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                              )
                                  : const Text('Save', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
