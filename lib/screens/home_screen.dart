import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import '../widgets/sidebar_drawer.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  File? _selectedImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final chatProvider = Provider.of<ChatProvider>(context, listen: false);
      
      // Set the user ID in ChatProvider
      if (authProvider.userId != null) {
        chatProvider.setUserId(authProvider.userId!);
      }
      
      if (chatProvider.currentChat == null && chatProvider.chats.isEmpty) {
        // Don't auto-create chat on login - let user create manually
        debugPrint('📱 No existing chats found - waiting for user to create chat manually');
      }
      // Initialize voice service
      chatProvider.initializeSpeech().then((_) {
        // Voice service initialized
      });
    });
  }

  Future<void> _pickImage() async {
    // TODO: Implement image picking
  }

  Future<void> _selectChat(String chatId) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    
    // Select chat directly (lock functionality not implemented)
    chatProvider.selectChat(chatId);
  }

  Future<void> _sendMessage() async {
    final message = _messageController.text.trim();
    if (message.isEmpty && _selectedImage == null) return;

    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    
    await chatProvider.sendMessage(
      message.isNotEmpty ? message : '[Image]',
      image: _selectedImage,
    );

    _messageController.clear();
    setState(() {
      _selectedImage = null;
    });
    
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (context, chatProvider, _) {
            return Text(
              chatProvider.currentChat?.title ?? 'AI Chatbot',
              style: const TextStyle(fontWeight: FontWeight.bold),
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () {
              Provider.of<ChatProvider>(context, listen: false).createNewChat();
            },
            tooltip: 'New Chat',
          ),
        ],
      ),
      drawer: const SidebarDrawer(),
      body: Column(
        children: [
          // Chat messages
          Expanded(
            child: Consumer<ChatProvider>(
              builder: (context, chatProvider, _) {
                if (chatProvider.messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start a conversation!',
                          style: TextStyle(
                            fontSize: 18,
                            color: Theme.of(context).textTheme.bodyLarge?.color?.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: chatProvider.messages.length + (chatProvider.isTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == chatProvider.messages.length) {
                      return const TypingIndicator();
                    }
                    
                    final message = chatProvider.messages[index];
                    return MessageBubble(message: message);
                  },
                );
              },
            ),
          ),

          // Image preview
          if (_selectedImage != null)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      _selectedImage!,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Image selected'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _selectedImage = null;
                      });
                    },
                  ),
                ],
              ),
            ),

          // Input area
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Row(
              children: [
                // Image picker button
                IconButton(
                  icon: const Icon(Icons.image),
                  onPressed: _pickImage,
                  tooltip: 'Add Image',
                ),
                
                // Text input
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                
                const SizedBox(width: 8),
                
                // Voice button
                Consumer<ChatProvider>(
                  builder: (context, chatProvider, _) {
                    return GestureDetector(
                      onTap: () async {
                        if (chatProvider.isVoiceChatMode) {
                          // If in voice chat mode, exit it
                          await chatProvider.toggleVoiceChatMode();
                        } else if (chatProvider.isVoiceListening) {
                          // If currently listening normally, stop it
                          await chatProvider.stopVoiceListening();
                        } else {
                          // Start continuous voice chat mode
                          await chatProvider.toggleVoiceChatMode();
                        }
                      },
                      onLongPress: () async {
                        // Long press now just does single voice command
                        if (!chatProvider.isVoiceChatMode) {
                          await chatProvider.startVoiceListening();
                        }
                      },
                      child: Tooltip(
                        message: chatProvider.isVoiceChatMode 
                            ? 'Tap to exit voice chat mode\nTap while listening to stop early (10-sec limit)\nLong press for single command'
                            : 'Tap to start voice chat mode (10-sec cycles)\nLong press for single command',
                        child: Container(
                          decoration: BoxDecoration(
                            color: chatProvider.isVoiceChatMode
                                ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                                : chatProvider.isVoiceListening
                                    ? Colors.red.withOpacity(0.1)
                                    : chatProvider.isVoiceSpeaking
                                        ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                                        : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: chatProvider.isVoiceChatMode
                                ? Border.all(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 2,
                                  )
                                : null,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  chatProvider.isVoiceChatMode
                                      ? Icons.mic
                                      : chatProvider.isVoiceListening
                                          ? Icons.stop_circle_rounded
                                          : Icons.mic_rounded,
                                  color: chatProvider.isVoiceChatMode
                                      ? Theme.of(context).colorScheme.primary
                                      : chatProvider.isVoiceListening
                                          ? Colors.red
                                          : chatProvider.isVoiceSpeaking
                                              ? Theme.of(context).colorScheme.primary
                                              : Theme.of(context).colorScheme.primary.withOpacity(0.7),
                                  size: 24,
                                ),
                                if (chatProvider.isVoiceChatMode)
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (chatProvider.isVoiceListening)
                                        Text(
                                          '10s',
                                          style: TextStyle(
                                            fontSize: 8,
                                            color: Colors.red,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      Text(
                                        'Live',
                                        style: TextStyle(
                                          fontSize: 8,
                                          color: Theme.of(context).colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                
                const SizedBox(width: 8),
                
                // Send button
                Consumer<ChatProvider>(
                  builder: (context, chatProvider, _) {
                    return IconButton(
                      icon: chatProvider.isTyping
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                      onPressed: chatProvider.isTyping ? null : _sendMessage,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
