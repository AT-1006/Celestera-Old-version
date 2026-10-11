import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class ChatLockService {
  static final ChatLockService _instance = ChatLockService._internal();
  factory ChatLockService() => _instance;
  ChatLockService._internal();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final LocalAuthentication auth = LocalAuthentication();
  
  String? _currentUserId;

  // Set current user ID for user-specific locks
  void setUserId(String userId) {
    _currentUserId = userId;
  }

  // Store locked chats
  Future<void> lockChat(String chatId, String pin) async {
    if (_currentUserId == null) return;
    await _secureStorage.write(key: '${_currentUserId}_chat_lock_$chatId', value: pin);
  }

  // Unlock chat with PIN
  Future<bool> unlockChatWithPin(String chatId, String pin) async {
    if (_currentUserId == null) return false;
    final storedPin = await _secureStorage.read(key: '${_currentUserId}_chat_lock_$chatId');
    return storedPin == pin;
  }

  // Check if chat is locked
  Future<bool> isChatLocked(String chatId) async {
    if (_currentUserId == null) return false;
    final pin = await _secureStorage.read(key: '${_currentUserId}_chat_lock_$chatId');
    return pin != null && pin.isNotEmpty;
  }

  // Unlock chat with biometrics
  Future<bool> unlockChatWithBiometrics() async {
    try {
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate = await auth.isDeviceSupported();

      if (!canAuthenticate || !canAuthenticateWithBiometrics) {
        return false;
      }

      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'Authenticate to unlock this chat',
        options: const AuthenticationOptions(
          biometricOnly: true,
          useErrorDialogs: true,
          stickyAuth: true,
        ),
      );

      return didAuthenticate;
    } catch (e) {
      return false;
    }
  }

  // Check if device supports biometrics
  Future<bool> isBiometricAvailable() async {
    try {
      final bool canCheckBiometrics = await auth.canCheckBiometrics;
      final bool isDeviceSupported = await auth.isDeviceSupported();
      return canCheckBiometrics && isDeviceSupported;
    } catch (e) {
      return false;
    }
  }

  // Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await auth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  // Remove chat lock
  Future<void> removeChatLock(String chatId) async {
    if (_currentUserId == null) return;
    await _secureStorage.delete(key: '${_currentUserId}_chat_lock_$chatId');
  }

  // Store global PIN for biometric setup (user-specific)
  Future<void> storeGlobalPin(String pin) async {
    if (_currentUserId == null) return;
    await _secureStorage.write(key: '${_currentUserId}_global_chat_pin', value: pin);
  }

  // Get global PIN (user-specific)
  Future<String?> getGlobalPin() async {
    if (_currentUserId == null) return null;
    return await _secureStorage.read(key: '${_currentUserId}_global_chat_pin');
  }

  // Clear global PIN (user-specific)
  Future<void> clearGlobalPin() async {
    if (_currentUserId == null) return;
    await _secureStorage.delete(key: '${_currentUserId}_global_chat_pin');
  }

  // Validate PIN format (4-6 digits)
  bool validatePin(String pin) {
    if (pin.length < 4 || pin.length > 6) return false;
    return RegExp(r'^\d+$').hasMatch(pin);
  }

  // Check if global PIN is set (user-specific)
  Future<bool> isGlobalPinSet() async {
    if (_currentUserId == null) return false;
    final pin = await getGlobalPin();
    return pin != null && pin.isNotEmpty;
  }
}
