import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class AuthProvider extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _nickname;
  String? _email;
  String? _photoURL;
  String? _userId;
  bool _isLoading = false;
  bool _isAuthenticated = false;

  String? get nickname => _nickname;
  String? get email => _email;
  String? get photoURL => _photoURL;
  String? get userId => _userId;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _isAuthenticated;

  User? get currentUser => _auth.currentUser;

  AuthProvider() {
    _loadUser();
    // Listen to auth state changes
    _auth.authStateChanges().listen((user) {
      debugPrint(' Auth state changed: ${user?.email}');
      if (user != null) {
        _userId = user.uid;
        _email = user.email;
        _photoURL = user.photoURL;
        _nickname = user.displayName ?? user.email?.split('@')[0];
        _isAuthenticated = true;
        debugPrint(' User authenticated: $_email (ID: $_userId)');
      } else {
        _userId = null;
        _email = null;
        _nickname = null;
        _photoURL = null;
        _isAuthenticated = false;
        debugPrint(' User signed out');
      }
      notifyListeners();
    });
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    _nickname = prefs.getString('nickname');
    _email = prefs.getString('email');
    _photoURL = prefs.getString('photoURL');
    _userId = prefs.getString('userId');
    _isAuthenticated = _userId != null;
    notifyListeners();
  }

  Future<bool> signInWithEmail(String email, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        await _saveUserData(credential.user!);
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      debugPrint('Email sign in error: ${e.message}');
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signUpWithEmail(String email, String password, String nickname) async {
    _isLoading = true;
    notifyListeners();

    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        // Update display name
        await credential.user!.updateDisplayName(nickname);

        // Create user document in Firestore
        await _firestore.collection('users').doc(credential.user!.uid).set({
          'uid': credential.user!.uid,
          'email': email,
          'nickname': nickname,
          'photoURL': null,
          'createdAt': FieldValue.serverTimestamp(),
          'lastLoginAt': FieldValue.serverTimestamp(),
        });

        await _saveUserData(credential.user!);
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      debugPrint('Email sign up error: ${e.message}');

      // Handle specific error codes
      if (e.code == 'email-already-in-use') {
        debugPrint('Email already exists - user should sign in instead');
        return false;
      } else if (e.code == 'weak-password') {
        debugPrint('Password is too weak');
        return false;
      } else if (e.code == 'invalid-email') {
        debugPrint('Email format is invalid');
        return false;
      }

      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }


Future<bool> signInWithGoogle() async {
  _isLoading = true;
  notifyListeners();

  try {
    debugPrint('=== Starting Google Sign-In ===');

    late final UserCredential userCredential;

    if (kIsWeb) {
      // WEB: Sign in using Firebase's Google popup.
      final GoogleAuthProvider provider = GoogleAuthProvider();
      provider.addScope('email');

      debugPrint('Opening Firebase Google popup...');
      userCredential = await _auth.signInWithPopup(provider);
    } else {
      // ANDROID / iOS: Keep Google Sign-In.
      final GoogleSignIn googleSignIn = GoogleSignIn(
        scopes: ['email', 'profile'],
        clientId:
            '48521747253-b2qkov3f9u397n4em41ji2ehdkdvo5ts.apps.googleusercontent.com',
      );

      final GoogleSignInAccount? googleUser =
          await googleSignIn.signIn();

      if (googleUser == null) {
        debugPrint('Google Sign-In cancelled');
        return false;
      }

      debugPrint('Google account selected: ${googleUser.email}');

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      if (googleAuth.idToken == null) {
        debugPrint('Google ID token is null');
        return false;
      }

      final OAuthCredential credential =
          GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      userCredential =
          await _auth.signInWithCredential(credential);
    }

    final User? user = userCredential.user;

    if (user == null) {
      debugPrint('Firebase returned no user');
      return false;
    }

    debugPrint('Firebase sign-in successful: ${user.email}');

    // Create or update the user's Firestore document.
    try {
      final userRef = _firestore.collection('users').doc(user.uid);
      final userDoc = await userRef.get();

      if (!userDoc.exists) {
        await userRef.set({
          'uid': user.uid,
          'email': user.email,
          'nickname':
              user.displayName ?? user.email?.split('@')[0],
          'photoURL': user.photoURL,
          'createdAt': FieldValue.serverTimestamp(),
          'lastLoginAt': FieldValue.serverTimestamp(),
          'provider': 'google',
        });
      } else {
        await userRef.update({
          'lastLoginAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('Firestore operation failed: $e');
    }

    await _saveUserData(user);
    debugPrint('Google user data saved successfully');

    return true;
  } catch (e, stackTrace) {
    debugPrint('Google Sign-In error: $e');
    debugPrintStack(stackTrace: stackTrace);
    rethrow;
  } finally {
    _isLoading = false;
    notifyListeners();
  }
}


  Future<void> signOut() async {
    try {
      await _auth.signOut();
      await GoogleSignIn().signOut();

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      _userId = null;
      _email = null;
      _nickname = null;
      _photoURL = null;
      _isAuthenticated = false;
      notifyListeners();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
  }

  Future<void> _saveUserData(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userId', user.uid);
    await prefs.setString('email', user.email ?? '');
    await prefs.setString('nickname', user.displayName ?? user.email?.split('@')[0] ?? '');
    await prefs.setString('photoURL', user.photoURL ?? '');
  }

  Future<void> updateNickname(String newNickname) async {
    try {
      await _auth.currentUser?.updateDisplayName(newNickname);

      if (_userId != null) {
        await _firestore.collection('users').doc(_userId).update({
          'nickname': newNickname,
        });
      }

      _nickname = newNickname;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nickname', newNickname);
      notifyListeners();
    } catch (e) {
      debugPrint('Update nickname error: $e');
    }
  }

  Future<void> updatePhotoURL(String newPhotoURL) async {
    try {
      await _auth.currentUser?.updatePhotoURL(newPhotoURL);

      if (_userId != null) {
        await _firestore.collection('users').doc(_userId).update({
          'photoURL': newPhotoURL,
        });
      }

      _photoURL = newPhotoURL;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('photoURL', newPhotoURL);
      notifyListeners();
    } catch (e) {
      debugPrint('Update photo URL error: $e');
    }
  }
}