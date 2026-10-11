import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../models/message_model.dart';
import '../models/chat_model.dart';
import '../services/database_service.dart';
import '../services/firebase_chat_service.dart';
import '../services/ai_services.dart';
import '../services/chat_lock_service.dart';
import '../services/chatbot_mode_service.dart';
import '../services/voice_service.dart';
import '../services/command_processor.dart';
import '../services/nlp_classifier.dart' as nlp;
import '../services/image_generation_service.dart';

class ChatProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService.instance;
  final AIService _aiService = AIService();
  final ChatLockService _chatLockService = ChatLockService();
  final ChatbotModeService _chatbotModeService = ChatbotModeService();
  final VoiceService _voiceService = VoiceService();
  final CommandProcessor _commandProcessor = CommandProcessor();
  final ImageGenerationService _imageService = ImageGenerationService();
  late FirebaseChatService _firebaseChatService;
  
  List<ChatModel> _chats = [];
  ChatModel? _currentChat;
  List<MessageModel> _messages = [];
  bool _isLoading = false;
  bool _isTyping = false;
  String? _currentUserId;

  List<ChatModel> get chats => _chats;
  ChatModel? get currentChat => _currentChat;
  List<MessageModel> get messages => _messages;
  bool get isLoading => _isLoading;
  bool get isTyping => _isTyping;
  String? get currentUserId => _currentUserId;

  ChatProvider() {
    // Don't load chats here - wait for user ID to be set
  }

  void setUserId(String userId) {
    debugPrint('=== Setting ChatProvider User ID: $userId ===');
    debugPrint('Previous user ID was: $_currentUserId');
    _currentUserId = userId;
    _firebaseChatService = FirebaseChatService(userId);
    
    // Set user ID in ChatLockService for user-specific locks
    _chatLockService.setUserId(userId);
    
    // Clear current state and reload from Firebase
    _chats = [];
    _currentChat = null;
    _messages = [];
    notifyListeners();
    
    // Load chats from Firebase
    _loadChats();
  }

  Future<void> _loadChats() async {
    if (_currentUserId == null) {
      debugPrint('❌ Cannot load chats - no user ID');
      debugPrint('Current user ID is null');
      return;
    }
    
    debugPrint('📁 Loading chats for user: $_currentUserId');
    debugPrint('Firebase service instance: $_firebaseChatService');
    try {
      _chats = await _firebaseChatService.getAllChats();
      debugPrint('✅ Loaded ${_chats.length} chats');
      for (var chat in _chats) {
        debugPrint('Chat: ${chat.id} - ${chat.title}');
      }
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error loading chats: $e');
      debugPrint('Stack trace: ${StackTrace.current}');
      _chats = [];
      notifyListeners();
    }
  }

  Future<void> createNewChat([String? title]) async {
    if (_currentUserId == null) return;
    
    final chatId = const Uuid().v4();
    final chat = ChatModel(
      id: chatId,
      title: title ?? 'New Chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _firebaseChatService.createChat(chat);
    _chats.insert(0, chat);
    _currentChat = chat;
    _messages = [];
    notifyListeners();
  }

  Future<void> selectChat(String chatId) async {
    if (_currentUserId == null) return;
    
    _currentChat = _chats.firstWhere((chat) => chat.id == chatId);
    _messages = await _firebaseChatService.getMessages(chatId);
    notifyListeners();
  }

  Future<void> deleteChat(String chatId) async {
    if (_currentUserId == null) return;
    
    await _firebaseChatService.deleteChat(chatId);
    _chats.removeWhere((chat) => chat.id == chatId);
    
    if (_currentChat?.id == chatId) {
      _currentChat = null;
      _messages = [];
    }
    
    notifyListeners();
  }

  Future<void> renameChat(String chatId, String newTitle) async {
    if (_currentUserId == null) return;
    
    final chat = _chats.firstWhere((c) => c.id == chatId);
    final updatedChat = chat.copyWith(
      title: newTitle,
      updatedAt: DateTime.now(),
    );
    
    await _firebaseChatService.updateChat(updatedChat);
    
    final index = _chats.indexWhere((c) => c.id == chatId);
    _chats[index] = updatedChat;
    
    if (_currentChat?.id == chatId) {
      _currentChat = updatedChat;
    }
    
    notifyListeners();
  }

  Future<void> sendMessage(String content, {File? image}) async {
    if (_currentChat == null || _currentUserId == null) {
      await createNewChat();
    }

    _isTyping = true;
    notifyListeners();

    String? imageUrl;
    if (image != null) {
      imageUrl = await _firebaseChatService.uploadImage(image, _currentChat!.id);
    }

    // Create user message
    final userMessage = MessageModel(
      id: const Uuid().v4(),
      chatId: _currentChat!.id,
      content: content,
      isUser: true,
      timestamp: DateTime.now(),
      imagePath: imageUrl,
    );

    await _firebaseChatService.sendMessage(userMessage);
    _messages.add(userMessage);
    notifyListeners();

    // Get AI response or process command
    try {
      String response;
      
      // First, check if this is a command
      try {
        final commandResult = await _commandProcessor.process(content);
        
        // If it's a command intent, execute it and use the command response
        switch (commandResult.intent) {
          case nlp.Intent.openWebsite:
          case nlp.Intent.searchGoogle:
          case nlp.Intent.searchYouTube:
          case nlp.Intent.playMusic:
          case nlp.Intent.openSpotify:
          case nlp.Intent.searchSpotify:
          case nlp.Intent.getNews:
            // This is a command - use the command result as response
            response = commandResult.message;
            break;
          case nlp.Intent.generateImage:
            // Handle image generation
            final prompt = commandResult.entities['prompt'] ?? 'beautiful landscape';
            await generateImage(prompt);
            return; // Don't send a text response, the image will be sent
          case nlp.Intent.changeVoice:
            // Handle voice change commands
            if (commandResult.entities['gender'] == 'male') {
              await setVoiceGender(VoiceGender.male);
              response = 'Voice changed to male.';
            } else if (commandResult.entities['gender'] == 'female') {
              await setVoiceGender(VoiceGender.female);
              response = 'Voice changed to female.';
            } else {
              response = commandResult.message;
            }
            break;
          case nlp.Intent.exitChat:
            // Handle exit command
            response = commandResult.message;
            break;
          default:
            // Not a recognized command, get AI response
            response = await _aiService.getChatResponse(
              content,
              conversationHistory: _messages,
              imagePath: imageUrl,
            );
            break;
        }
      } catch (e) {
        // If command processing fails, fall back to AI response
        debugPrint('Command processing error: $e');
        response = await _aiService.getChatResponse(
          content,
          conversationHistory: _messages,
          imagePath: imageUrl,
        );
      }

      final botMessage = MessageModel(
        id: const Uuid().v4(),
        chatId: _currentChat!.id,
        content: response,
        isUser: false,
        timestamp: DateTime.now(),
      );

      await _firebaseChatService.sendMessage(botMessage);
      _messages.add(botMessage);

      // Auto-generate chat title if first message
      if (_messages.length == 2 && _currentChat!.title == 'New Chat') {
        final title = await _generateChatTitle(content);
        await renameChat(_currentChat!.id, title);
      }

      // Update chat timestamp
      final updatedChat = _currentChat!.copyWith(
        updatedAt: DateTime.now(),
      );
      await _firebaseChatService.updateChat(updatedChat);

    } catch (e) {
      debugPrint('AI Service Error: $e');
      
      String userFriendlyError = 'Sorry, I encountered an error. Please try again.';
      
      // Check for specific error types and provide better messages
      if (e.toString().contains('network') || e.toString().contains('connection')) {
        userFriendlyError = 'Network error. Please check your internet connection and try again.';
      } else if (e.toString().contains('timeout')) {
        userFriendlyError = 'Request timed out. Please try again.';
      } else if (e.toString().contains('api') || e.toString().contains('key')) {
        userFriendlyError = 'Service temporarily unavailable. Please try again later.';
      } else if (e.toString().contains('rate') || e.toString().contains('limit')) {
        userFriendlyError = 'Too many requests. Please wait a moment and try again.';
      }
      
      final errorMessage = MessageModel(
        id: const Uuid().v4(),
        chatId: _currentChat!.id,
        content: userFriendlyError,
        isUser: false,
        timestamp: DateTime.now(),
      );

      await _firebaseChatService.sendMessage(errorMessage);
      _messages.add(errorMessage);
    }

    _isTyping = false;
    notifyListeners();
  }

  Future<String> _generateChatTitle(String firstMessage) async {
    try {
      final title = await _aiService.generateTitle(firstMessage);
      return title.length > 50 ? '${title.substring(0, 47)}...' : title;
    } catch (e) {
      return firstMessage.length > 30
          ? '${firstMessage.substring(0, 27)}...'
          : firstMessage;
    }
  }

  Future<void> clearCurrentChat() async {
    if (_currentChat == null || _currentUserId == null) return;
    
    await _firebaseChatService.clearChatMessages(_currentChat!.id);
    _messages = [];
    notifyListeners();
  }

  // Chat Lock Methods
  Future<void> lockChat(String chatId, String pin) async {
    await _chatLockService.lockChat(chatId, pin);
    notifyListeners();
  }

  Future<void> unlockChat(String chatId) async {
    await _chatLockService.removeChatLock(chatId);
    notifyListeners();
  }

  Future<bool> isChatLocked(String chatId) async {
    return await _chatLockService.isChatLocked(chatId);
  }

  Future<bool> unlockChatWithPin(String chatId, String pin) async {
    return await _chatLockService.unlockChatWithPin(chatId, pin);
  }

  Future<bool> unlockChatWithBiometrics() async {
    return await _chatLockService.unlockChatWithBiometrics();
  }

  // Chatbot Mode Methods
  Future<void> setChatbotMode(ChatbotMode mode) async {
    await _chatbotModeService.saveChatbotMode(mode);
    notifyListeners();
  }

  Future<ChatbotMode> getCurrentChatbotMode() async {
    return await _chatbotModeService.getCurrentMode();
  }

  List<ChatbotMode> getAllChatbotModes() {
    return _chatbotModeService.getAllModes();
  }

  bool _isVoiceChatMode = false; // Separate voice chat mode

  // Voice Methods
  Future<bool> initializeSpeech() async {
    return await _voiceService.initializeSpeech();
  }

  bool get isVoiceListening => _voiceService.isListening;
  bool get isVoiceSpeaking => _voiceService.isSpeaking;
  bool get isVoiceChatMode => _isVoiceChatMode;
  VoiceGender get voiceGender => _voiceService.currentGender;

  Future<void> startVoiceListening() async {
    if (_voiceService.isListening) return;

    if (_isVoiceChatMode) {
      // Use new continuous mode for voice chat
      await _voiceService.startContinuousListening(
        onResult: (command) async {
          debugPrint('🎤 Voice command received: $command');
          await _processVoiceCommandOnly(command);
        },
        onListeningStop: () {
          debugPrint('🎤 Listening stopped (continuous mode)');
          notifyListeners();
        },
      );
    } else {
      // Use legacy method for single commands
      await _voiceService.startListening(
        onResult: (command) async {
          debugPrint('🎤 Voice command received: $command');
          await _processVoiceCommand(command);
        },
        onListeningStop: () {
          debugPrint('🎤 Listening stopped (single command)');
          notifyListeners();
        },
        continuousMode: false,
      );
    }
    notifyListeners();
  }

  Future<void> stopVoiceListening() async {
    await _voiceService.stopListening();
    notifyListeners();
  }

  Future<void> toggleVoiceChatMode() async {
    _isVoiceChatMode = !_isVoiceChatMode;
    
    if (_isVoiceChatMode) {
      // Start continuous listening immediately without TTS
      debugPrint('🎤 Starting voice chat mode (continuous)');
      await startVoiceListening();
    } else {
      // Stop continuous listening when exiting voice chat mode
      debugPrint('🛑 Stopping voice chat mode');
      await _voiceService.stopContinuousListening();
      await speakText('Voice chat mode deactivated.');
    }
    
    notifyListeners();
  }

  Future<void> setVoiceChatMode(bool enabled) async {
    _isVoiceChatMode = enabled;
    
    if (enabled) {
      debugPrint('🎤 Enabling voice chat mode (continuous)');
      await startVoiceListening();
    } else {
      debugPrint('🛑 Disabling voice chat mode');
      await _voiceService.stopContinuousListening();
      await speakText('Voice chat mode deactivated.');
    }
    
    notifyListeners();
  }

  Future<void> toggleVoiceGender() async {
    // Toggle between male and female
    final newGender = voiceGender == VoiceGender.male ? VoiceGender.female : VoiceGender.male;
    await setVoiceGender(newGender);
    notifyListeners();
  }

  Future<void> setVoiceGender(VoiceGender gender) async {
    await _voiceService.setVoiceGender(gender);
    notifyListeners();
  }

  Future<void> speakText(String text) async {
    if (_isVoiceChatMode) {
      // In voice chat mode, restart listening after TTS completes
      await _voiceService.speak(text, onComplete: () {
        if (_isVoiceChatMode && !_voiceService.isListening) {
          debugPrint('🔄 Restarting listening after TTS completion');
          Future.delayed(const Duration(milliseconds: 50), () {
            if (_isVoiceChatMode && !_voiceService.isListening) {
              startVoiceListening();
            }
          });
        }
      });
    } else {
      // Normal mode - just speak
      await _voiceService.speak(text);
    }
  }

  Future<void> _processVoiceCommand(String command) async {
    if (command.trim().isEmpty) return;

    // Add user message
    await sendMessage(command);

    // Process command with NLP
    try {
      final result = await _commandProcessor.process(command);
      
      // Handle special intents
      switch (result.intent) {
        case nlp.Intent.changeVoice:
          if (result.entities['gender'] == 'male') {
            await setVoiceGender(VoiceGender.male);
          } else if (result.entities['gender'] == 'female') {
            await setVoiceGender(VoiceGender.female);
          }
          break;
        case nlp.Intent.exitChat:
          await stopVoiceListening();
          break;
        default:
          // For other intents, just let the normal chat flow handle it
          break;
      }

      // Speak the response
      await speakText(result.message);
    } catch (e) {
      debugPrint('Voice command processing error: $e');
      await speakText('Sorry, I had trouble processing that command.');
    }
  }

  Future<void> _processVoiceCommandOnly(String command) async {
    if (command.trim().isEmpty) return;

    // Process command with NLP
    try {
      final result = await _commandProcessor.process(command);
      
      // Handle special intents
      switch (result.intent) {
        case nlp.Intent.changeVoice:
          if (result.entities['gender'] == 'male') {
            await setVoiceGender(VoiceGender.male);
            await speakText('Voice changed to male.');
          } else if (result.entities['gender'] == 'female') {
            await setVoiceGender(VoiceGender.female);
            await speakText('Voice changed to female.');
          }
          break;
        case nlp.Intent.exitChat:
          await toggleVoiceChatMode(); // Exit voice chat mode
          break;
        case nlp.Intent.openWebsite:
        case nlp.Intent.searchGoogle:
        case nlp.Intent.searchYouTube:
        case nlp.Intent.playMusic:
        case nlp.Intent.openSpotify:
        case nlp.Intent.searchSpotify:
        case nlp.Intent.getNews:
          // For command intents, speak the result message
          await speakText(result.message);
          break;
        case nlp.Intent.generateImage:
          // Handle image generation
          final prompt = result.entities['prompt'] ?? 'beautiful landscape';
          await generateImage(prompt);
          break;
        default:
          // For general chat, get AI response and speak it
          try {
            final response = await _aiService.getChatResponse(
              command,
              conversationHistory: _messages,
            );
            await speakText(response);
          } catch (e) {
            debugPrint('AI Service Error in voice mode: $e');
            await speakText('Sorry, I had trouble processing that request.');
          }
          break;
      }
    } catch (e) {
      debugPrint('Voice command processing error: $e');
      await speakText('Sorry, I had trouble processing that command.');
    }
  }

  void clearMessages() {
    debugPrint('🧹 Clearing chat messages and current state');
    _messages = [];
    _currentChat = null;
    _chats = [];
    // Clear user ID from ChatLockService when logging out
    _chatLockService.setUserId('');
    // Don't clear _currentUserId so we can reload data when user logs back in
    notifyListeners();
  }

  // =============================
  // Image Generation Methods
  // =============================
  
  Future<File?> generateImage(String prompt) async {
    try {
      debugPrint('🎨 Generating image: $prompt');
      
      // Set loading state
      _isLoading = true;
      notifyListeners();
      
      // Use the new clean method that returns bytes directly
      final imageBytes = await _imageService.generateImageBytes(prompt);
      
      if (imageBytes != null) {
        debugPrint('✅ Image generated successfully: ${imageBytes.length} bytes');
        
        // Create file from bytes
        final tempDir = Directory.systemTemp;
        final fileName = 'generated_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final imageFile = File('${tempDir.path}/$fileName');
        await imageFile.writeAsBytes(imageBytes);
        
        debugPrint('📁 Image saved to: ${imageFile.path}');
        
        // Send the generated image as a message
        await _sendImageMessage('Generated image: $prompt', imageFile);
        
        // Clear loading state after everything is done
        _isLoading = false;
        notifyListeners();
        
        return imageFile;
      } else {
        debugPrint('❌ Failed to generate image');
        _isLoading = false;
        notifyListeners();
        await _sendTextMessage('Sorry, I failed to generate the image. Please try again.');
        return null;
      }
    } catch (e) {
      debugPrint('🔥 Error generating image: $e');
      _isLoading = false;
      notifyListeners();
      await _sendTextMessage('Sorry, I encountered an error while generating the image.');
      return null;
    }
  }

  Future<void> _sendImageMessage(String content, File image) async {
    if (_currentChat == null || _currentUserId == null) {
      await createNewChat();
    }

    String? imageUrl;
    
    try {
      debugPrint(' Uploading image to Firebase...');
      
      // Add timeout to prevent hanging
      imageUrl = await _firebaseChatService.uploadImage(image, _currentChat!.id)
          .timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('Firebase upload timed out after 30 seconds');
      });
      
      debugPrint(' Image uploaded to Firebase: $imageUrl');
    } catch (e) {
      debugPrint(' Firebase upload failed: $e');
      debugPrint(' Using local file path as fallback...');
      // Fallback: use local file path if Firebase upload fails
      imageUrl = image.path;
    }

    // Create bot message with image
    final botMessage = MessageModel(
      id: const Uuid().v4(),
      chatId: _currentChat!.id,
      content: content,
      isUser: false,
      timestamp: DateTime.now(),
      imagePath: imageUrl,
    );

    await _firebaseChatService.sendMessage(botMessage);
    _messages.add(botMessage);
    notifyListeners();

    // Update chat timestamp
    final updatedChat = _currentChat!.copyWith(
      updatedAt: DateTime.now(),
    );
    await _firebaseChatService.updateChat(updatedChat);
  }

  Future<void> _sendTextMessage(String content) async {
    if (_currentChat == null || _currentUserId == null) {
      await createNewChat();
    }

    // Create bot message
    final botMessage = MessageModel(
      id: const Uuid().v4(),
      chatId: _currentChat!.id,
      content: content,
      isUser: false,
      timestamp: DateTime.now(),
    );

    await _firebaseChatService.sendMessage(botMessage);
    _messages.add(botMessage);
    notifyListeners();

    // Update chat timestamp
    final updatedChat = _currentChat!.copyWith(
      updatedAt: DateTime.now(),
    );
    await _firebaseChatService.updateChat(updatedChat);
  }

  Future<void> testImageGeneration() async {
    debugPrint('🧪 Testing image generation from ChatProvider...');
    await _imageService.testDirectCall();
  }
}