import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../constants.dart';
import 'api_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: AppConstants.googleServerClientId,
    scopes: const ['email', 'profile', 'openid'],
  );

  GoogleSignInAccount? _account;
  String? _idToken;

  GoogleSignInAccount? get currentUser => _account;
  String? get idToken => _idToken;
  bool get isSignedIn => _account != null && _idToken != null && _idToken!.isNotEmpty;

  Future<bool> tryRestoreSession() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account == null) {
        _clear();
        return false;
      }
      return _hydrateAccount(account);
    } catch (e) {
      debugPrint('[AUTH] restore error: $e');
      _clear();
      return false;
    }
  }

  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        _clear();
        return false;
      }
      return _hydrateAccount(account);
    } catch (e) {
      debugPrint('[AUTH] sign-in error: $e');
      _clear();
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      debugPrint('[AUTH] sign-out error: $e');
    }
    _clear();
  }

  Future<bool> refreshTokenIfNeeded() async {
    try {
      final account = _account ?? await _googleSignIn.signInSilently();
      if (account == null) {
        _clear();
        return false;
      }
      return _hydrateAccount(account);
    } catch (e) {
      debugPrint('[AUTH] refresh error: $e');
      _clear();
      return false;
    }
  }

  Future<bool> _hydrateAccount(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    final token = auth.idToken;

    if (token == null || token.isEmpty) {
      debugPrint('[AUTH] missing Google ID token');
      _clear();
      return false;
    }

    _account = account;
    _idToken = token;
    ApiService().setBearerToken(token);
    return true;
  }

  void _clear() {
    _account = null;
    _idToken = null;
    ApiService().setBearerToken(null);
  }
}