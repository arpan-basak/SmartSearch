import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_search_app/features/account/data/firebase_config.dart';

/// Syncs only non-sensitive app preferences. Search history, contacts,
/// installed apps and documents stay local.
class AccountSync {
  AccountSync({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  bool _googleInitialized = false;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;
  bool get supportsGoogleSignIn =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  Future<User?> signInWithGoogle() async {
    if (kIsWeb) {
      final credential = await _auth.signInWithPopup(GoogleAuthProvider());
      return credential.user;
    }
    if (!supportsGoogleSignIn) {
      throw StateError('Google sign-in is not configured for this platform.');
    }

    if (!_googleInitialized) {
      // Android can read the web OAuth client from google-services.json. Keep
      // the build-time value optional so either supported Firebase setup works.
      await GoogleSignIn.instance.initialize(
        serverClientId: FirebaseConfig.googleWebClientId.isEmpty
            ? null
            : FirebaseConfig.googleWebClientId,
      );
      _googleInitialized = true;
    }
    final googleUser = await GoogleSignIn.instance.authenticate();
    final googleAuth = googleUser.authentication;
    final credential =
        GoogleAuthProvider.credential(idToken: googleAuth.idToken);
    return (await _auth.signInWithCredential(credential)).user;
  }

  /// Uses Firebase's Apple OAuth provider. On Android this opens Apple's
  /// secure web flow; on Apple platforms it uses the native-capable flow.
  Future<User?> signInWithApple() async {
    if (kIsWeb) {
      return (await _auth.signInWithPopup(OAuthProvider('apple.com'))).user;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      throw StateError('Apple sign-in is not supported on this platform.');
    }
    return (await _auth.signInWithProvider(OAuthProvider('apple.com'))).user;
  }

  Future<void> signOut() => _auth.signOut();

  /// Short-lived proof used by the Cloudflare Worker. The Worker derives the
  /// UID from this token and never accepts a UID from a request body.
  Future<String?> getIdToken({bool forceRefresh = false}) => currentUser == null
      ? Future<String?>.value()
      : currentUser!.getIdToken(forceRefresh);

  /// Converts provider failures into guidance a user can act on. In
  /// particular, Android's Credential Manager reports several OAuth setup
  /// failures as a cancellation after account selection.
  static String signInErrorMessage(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is FirebaseAuthException) {
      return error.message ?? 'Firebase could not complete the sign-in.';
    }
    if (error is GoogleSignInException) {
      switch (error.code) {
        case GoogleSignInExceptionCode.canceled:
          return 'Google sign-in was cancelled. If this happens after choosing an account, check the Android package name, signing SHA-1, and web OAuth client.';
        case GoogleSignInExceptionCode.clientConfigurationError:
          return 'Google sign-in is not configured for this app build. Check the Android package name, signing SHA-1, and web OAuth client in Firebase.';
        default:
          return 'Google sign-in could not be completed. Please try again.';
      }
    }
    return 'Google sign-in could not be completed. Please try again.';
  }

  DocumentReference<Map<String, dynamic>>? get _preferenceDocument {
    final uid = currentUser?.uid;
    return uid == null ? null : _firestore.collection('users').doc(uid);
  }

  Future<int?> loadThemeMode() async {
    final reference = _preferenceDocument;
    if (reference == null) return null;
    final data = (await reference.get()).data();
    final value = data?['themeMode'];
    return value is int && value >= 0 && value <= 2 ? value : null;
  }

  Future<void> saveThemeMode(int value) async {
    if (value < 0 || value > 2) return;
    final reference = _preferenceDocument;
    if (reference == null) return;
    await reference.set({
      'themeMode': value,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
