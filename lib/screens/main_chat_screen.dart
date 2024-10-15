import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:google_fonts/google_fonts.dart';

class MainChatScreen extends StatefulWidget {
  final String phoneNumber;

  MainChatScreen({required this.phoneNumber});

  @override
  _MainChatScreenState createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen> with TickerProviderStateMixin {
  FlutterSoundRecorder? _recorder;
  bool _isRecording = false;
  bool _isProcessing = false;
  String _transcription = '';
  String _aiResponse = '';
  String _elevenLabsResponse = '';
  List<Map<String, dynamic>> _chatHistory = [];
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String _audioFilePath = '';
  AudioPlayer _audioPlayer = AudioPlayer();
  ScrollController _scrollController = ScrollController();
  StreamController<String>? _streamController;
  bool _isPlaying = false;
  int _recordingDuration = 0;
  Timer? _timer;
  bool _showScrollToBottomButton = false;

  late AnimationController _recordingAnimationController;
  late Animation<double> _recordingAnimation;
  late AnimationController _processingAnimationController;
  late AnimationController _voiceStrokeController;
  List<double> _voiceStrokeHeights = List.filled(10, 0.0);

  @override
  void initState() {
    super.initState();
    _initRecorder();
    _loadChatHistory();
    _audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        _isPlaying = false;
      });
    });
    _scrollController.addListener(_scrollListener);

    _recordingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);
    _recordingAnimation = Tween<double>(begin: 0, end: 1).animate(_recordingAnimationController);

    _processingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();


    _voiceStrokeController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 50),
    )..addListener(() {
      setState(() {
        for (int i = 0; i < _voiceStrokeHeights.length; i++) {
          _voiceStrokeHeights[i] = (0.1 + 0.9 * _voiceStrokeController.value) * (i % 3 + 1) / 3;
        }
      });
    });
  }

  void _scrollListener() {
    if (_scrollController.offset < _scrollController.position.maxScrollExtent - 100) {
      setState(() {
        _showScrollToBottomButton = true;
      });
    } else {
      setState(() {
        _showScrollToBottomButton = false;
      });
    }
  }

  String _decodeText(String input) {
    try {
      // First, try to decode as UTF-8
      return utf8.decode(input.runes.toList());
    } catch (e) {
      try {
        // If UTF-8 fails, try to decode as Latin-1 and then as UTF-8
        return utf8.decode(latin1.encode(input));
      } catch (e) {
        print('Failed to decode text: $e');
        return input; // Return original input if all decoding attempts fail
      }
    }
  }

  Future<void> _initRecorder() async {
    print('🎙️ _initRecorder: Setting up audio recorder');
    _recorder = FlutterSoundRecorder();
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      print('❌ _initRecorder: Microphone permission denied');
      throw RecordingPermissionException('Microphone permission not granted');
    }
    await _recorder!.openRecorder();
    print('✅ _initRecorder: Audio recorder setup complete');
  }

  Future<void> _loadChatHistory() async {
    print('📚 _loadChatHistory: Fetching chat history from Firestore');
    QuerySnapshot snapshot = await _firestore
        .collection('chat_history')
        .doc(widget.phoneNumber)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(50)  // Limit to last 50 messages for performance
        .get();

    setState(() {
      _chatHistory = snapshot.docs.map((doc) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return {
          'role': data['role'] as String,
          'message': _decodeText(data['message'] as String),
          'aiResponse': data['aiResponse'] != null ? _decodeText(data['aiResponse'] as String) : null,
          'elevenLabsResponse': data['elevenLabsResponse'] as String?,
          'timestamp': data['timestamp'] as Timestamp,
        };
      }).toList().reversed.toList();
    });

    print('✅ _loadChatHistory: Chat history loaded with ${_chatHistory.length} messages');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _saveChatMessage(String role, String message, {String? aiResponse, String? elevenLabsResponse}) async {
    print('💾 _saveChatMessage: Saving message to Firestore');
    await _firestore
        .collection('chat_history')
        .doc(widget.phoneNumber)
        .collection('messages')
        .add({
      'role': role,
      'message': message,
      'aiResponse': aiResponse,
      'elevenLabsResponse': elevenLabsResponse,
      'timestamp': FieldValue.serverTimestamp(),
    });
    print('✅ _saveChatMessage: Message saved successfully');
  }

  Future<void> _startRecording() async {
    if (_isProcessing) {
      print('⚠️ Cannot start recording: Still processing previous input');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please wait for the previous input to be processed.')),
      );
      return;
    }

    print('🎬 _startRecording: Initiating audio recording');
    try {
      _voiceStrokeController.repeat(reverse: true);
      Directory tempDir = await getTemporaryDirectory();
      _audioFilePath = '${tempDir.path}/audio.wav';
      await _recorder!.startRecorder(
        toFile: _audioFilePath,
        codec: Codec.pcm16WAV,
      );
      setState(() {
        _isRecording = true;
        _recordingDuration = 0;
      });
      _startTimer();
      print('✅ _startRecording: Recording started successfully');
    } catch (e) {
      print('❌ _startRecording: Error starting recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording. Please try again.')),
      );
    }
  }

  Future<void> _stopRecording() async {
    print('🛑 _stopRecording: Stopping audio recording');
    try {
      _voiceStrokeController.stop();
      await _recorder!.stopRecorder();
      _stopTimer();
      setState(() {
        _isRecording = false;
        _isProcessing = true;
      });
      print('✅ _stopRecording: Recording stopped successfully');
      await _processRecording();
    } catch (e) {
      print('❌ _stopRecording: Error stopping recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to stop recording. Please try again.')),
      );
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        _recordingDuration++;
      });
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _processRecording() async {
    try {
      await _transcribeAudio();
      await _getAIResponse();
      await _generateAndPlayAudio(_aiResponse);
    } catch (e) {
      print('❌ _processRecording: Error processing recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('An error occurred while processing your input. Please try again.')),
      );
    } finally {
      setState(() {
        _isProcessing = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _transcribeAudio() async {
    print('🗣️ _transcribeAudio: Transcribing audio with OpenAI Whisper');
    final String apiKey = '';
    final Uri url = Uri.parse('https://api.openai.com/v1/audio/transcriptions');

    try {
      var request = http.MultipartRequest('POST', url)
        ..headers.addAll({
          'Authorization': 'Bearer $apiKey',
        })
        ..files.add(await http.MultipartFile.fromPath('file', _audioFilePath))
        ..fields['model'] = 'whisper-1';

      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var jsonResponse = json.decode(responseData) as Map<String, dynamic>;
        String rawTranscription = jsonResponse['text'] as String;
        print('Raw transcription: $rawTranscription');

        setState(() {
          _transcription = _decodeText(rawTranscription);
        });
        print('Decoded transcription: $_transcription');

        await _saveChatMessage('user', _transcription);
        _chatHistory.add({
          'role': 'user',
          'message': _transcription,
          'aiResponse': null,
          'elevenLabsResponse': null,
          'timestamp': Timestamp.now(),
        });
        print('✅ _transcribeAudio: Audio transcribed successfully');
      } else {
        print('❌ _transcribeAudio: Failed to transcribe audio: ${response.statusCode}');
        print('Response body: ${await response.stream.bytesToString()}');
      }
    } catch (e) {
      print('❌ _transcribeAudio: Error transcribing audio: $e');
    }
  }

  Future<String> _fetchPromptFromFirestore() async {
    try {
      DocumentSnapshot documentSnapshot = await FirebaseFirestore.instance
          .collection('prompt')
          .doc('Y1hUgoxJ63oSy1dHNFmk')
          .get();
      if (documentSnapshot.exists) {
        String prompt = documentSnapshot['prompt'] as String;
        print('DEBUG: Fetched prompt from Firebase: $prompt');
        return prompt;
      } else {
        print('DEBUG: Prompt document does not exist');
        return 'Default prompt or instructions if not found';
      }
    } catch (e) {
      print('DEBUG: Error fetching prompt: $e');
      return 'Default prompt or instructions in case of an error';
    }
  }

  Future<String> _fetchModelNameFromFirestore() async {
    try {
      DocumentSnapshot documentSnapshot = await FirebaseFirestore.instance
          .collection('modelName')
          .doc('EMb3LvuVMxhUHggBMhXX')
          .get();
      if (documentSnapshot.exists) {
        String modelName = documentSnapshot['modelName'] as String;
        print('DEBUG: Fetched model name from Firebase: $modelName');
        return modelName;
      } else {
        print('DEBUG: Model name document does not exist');
        return 'anthropic/claude-3.5-sonnet'; // Default model as fallback
      }
    } catch (e) {
      print('DEBUG: Error fetching model name: $e');
      return 'anthropic/claude-3.5-sonnet'; // Default model as fallback
    }
  }

  Future<void> _getAIResponse() async {
    print('🤖 _getAIResponse: Fetching AI response from OpenRouter');
    final OPENROUTER_API_KEY = '';
    final YOUR_SITE_URL = 'google.com';
    final YOUR_SITE_NAME = 'invue';

    try {
      final userInstruction = await _fetchPromptFromFirestore();
      final modelName = await _fetchModelNameFromFirestore();
      print("DEBUG: Prompt being sent to OpenRouter: $userInstruction");
      print("DEBUG: Model name being used: $modelName");

      _streamController = StreamController<String>();
      setState(() {
        _chatHistory.add({
          'role': 'assistant',
          'message': '',
          'aiResponse': '',
          'elevenLabsResponse': null,
          'timestamp': Timestamp.now(),
        });
      });
      _scrollToBottom();

      // Construct the messages array
      final List<Map<String, String>> messages = [
        {'role': 'system', 'content': userInstruction},
        ..._chatHistory.map((msg) => {
          'role': msg['role'] as String,
          'content': msg['message'] as String,
        }).toList(),
      ];

      // Construct the request body
      final requestBody = {
        'model': modelName,
        'messages': messages,
      };

      // Debug print the entire request body
      print('DEBUG: Full OpenRouter request body:');
      print(JsonEncoder.withIndent('  ').convert(requestBody));

      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $OPENROUTER_API_KEY',
          'HTTP-Referer': YOUR_SITE_URL,
          'X-Title': YOUR_SITE_NAME,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      );

      print('DEBUG: OpenRouter response status code: ${response.statusCode}');
      print('DEBUG: OpenRouter response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final fullResponse = data['choices'][0]['message']['content'] as String;
        print('Raw AI response: $fullResponse');

        // Stream the text response in chunks
        List<String> chunks = _splitIntoChunks(fullResponse);
        for (String chunk in chunks) {
          String decodedChunk = _decodeText(chunk);
          _streamController?.add(decodedChunk);
          setState(() {
            _chatHistory.last['message'] = (_chatHistory.last['message'] as String) + decodedChunk;
          });
          await Future.delayed(Duration(milliseconds: 50));
          _scrollToBottom();
        }

        setState(() {
          _aiResponse = _chatHistory.last['message'] as String;
          _chatHistory.last['aiResponse'] = _aiResponse;
        });
        print('Decoded AI response: $_aiResponse');

        await _saveChatMessage('assistant', _aiResponse, aiResponse: _aiResponse);

        // Generate and play audio after the full response is received
        await _generateAndPlayAudio(_aiResponse);

        print('✅ _getAIResponse: AI response received and processed successfully');
      } else {
        print('❌ _getAIResponse: Failed to get AI response: ${response.statusCode}');
        print('Response body: ${response.body}');
      }
    } catch (e) {
      print('❌ _getAIResponse: Error getting AI response: $e');
    } finally {
      _streamController?.close();
      _scrollToBottom();
    }
  }


  List<String> _splitIntoChunks(String text, {int chunkSize = 10}) {
    return text.split(' ').fold<List<String>>([], (chunks, word) {
      if (chunks.isEmpty || chunks.last.split(' ').length >= chunkSize) {
        chunks.add(word);
      } else {
        chunks[chunks.length - 1] += ' $word';
      }
      return chunks;
    });
  }




  Future<void> _generateAndPlayAudio(String text) async {
    print('🔊 _generateAndPlayAudio: Generating and playing audio with Eleven Labs');
    final ELEVEN_LABS_API_KEY = '';
    final ELEVEN_LABS_VOICE_ID = '9BWtsMINqrJLrRacOk9x';

    try {
      // Remove any parenthetical translations to avoid repetition
      final cleanedText = text.replaceAll(RegExp(r'\([^)]*\)'), '').trim();

      final response = await http.post(
        Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$ELEVEN_LABS_VOICE_ID/stream'),
        headers: {
          'Accept': 'audio/mpeg',
          'xi-api-key': ELEVEN_LABS_API_KEY,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'text': cleanedText,
          'model_id': 'eleven_multilingual_v1',
          'voice_settings': {
            'stability': 0.5,
            'similarity_boost': 0.5,
          }
        }),
      );

      if (response.statusCode == 200) {
        Directory tempDir = await getTemporaryDirectory();
        String filePath = '${tempDir.path}/tts_output.mp3';
        File audioFile = File(filePath);
        await audioFile.writeAsBytes(response.bodyBytes);

        setState(() {
          _isPlaying = true;
          _elevenLabsResponse = 'Audio generated successfully';
          _chatHistory.last['elevenLabsResponse'] = _elevenLabsResponse;
        });
        await _audioPlayer.play(DeviceFileSource(filePath));
        print('✅ _generateAndPlayAudio: Audio generated and played successfully');
      } else {
        print('❌ _generateAndPlayAudio: Failed to generate audio: ${response.statusCode}');
        print('Response body: ${response.body}');
      }
    } catch (e) {
      print('❌ _generateAndPlayAudio: Error generating or playing audio: $e');
    }
  }

  void _stopAudio() {
    _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
    });
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Invue Chat', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: Color(0xFF6A11CB),
        elevation: 0,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF6A11CB), Color(0xFF2575FC)],
          ),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.all(16),
                    itemCount: _chatHistory.length,
                    itemBuilder: (context, index) {
                      final message = _chatHistory[index];
                      return _buildMessageBubble(message, index == _chatHistory.length - 1);
                    },
                  ),
                ),
                _buildInputArea(),
              ],
            ),
            if (_showScrollToBottomButton)
              Positioned(
                right: 16,
                bottom: 80,
                child: FloatingActionButton(
                  onPressed: _scrollToBottom,
                  child: Icon(Icons.arrow_downward),
                  mini: true,
                  backgroundColor: Colors.white,
                  foregroundColor: Color(0xFF6A11CB),
                ),
              ),
          ],
        ),
      ),
    );
  }


  Widget _buildMessageBubble(Map<String, dynamic> message, bool isLatest) {
    final isUser = message['role'] == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Color(0xFF2575FC) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 5,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUser ? 'You' : 'AI',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.bold,
                color: isUser ? Colors.white : Color(0xFF6A11CB),
              ),
            ),
            SizedBox(height: 4),
            Text(
              message['message'] as String,
              style: GoogleFonts.poppins(
                color: isUser ? Colors.white : Colors.black87,
              ),
            ),
            if (message['elevenLabsResponse'] != null)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '🔊 ${message['elevenLabsResponse']}',
                      style: GoogleFonts.poppins(
                        color: isUser ? Colors.white70 : Color(0xFF6A11CB).withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(width: 8),
                    if (_isPlaying)
                      IconButton(
                        icon: Icon(Icons.stop, size: 20, color: isUser ? Colors.white : Color(0xFF6A11CB)),
                        onPressed: _stopAudio,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                ElevatedButton(
                  onPressed: _isProcessing ? null : (_isRecording ? _stopRecording : _startRecording),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.red : Color(0xFF6A11CB),
                    padding: EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    elevation: 5,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isRecording)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CustomPaint(
                            painter: VoiceStrokesPainter(_voiceStrokeHeights),
                          ),
                        )
                      else
                        Icon(Icons.mic, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        _isRecording ? 'Recording...' : (_isProcessing ? 'Processing...' : 'Start Recording'),
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isProcessing)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_isRecording)
            SizedBox(width: 16),
          if (_isRecording)
            Container(
              width: 50,
              height: 50,
              child: ElevatedButton(
                onPressed: _stopRecording,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: EdgeInsets.zero,
                ),
                child: Icon(Icons.stop, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _recorder!.closeRecorder();
    _audioPlayer.dispose();
    _scrollController.dispose();
    _streamController?.close();
    _recordingAnimationController.dispose();
    _processingAnimationController.dispose();
    _voiceStrokeController.dispose();
    super.dispose();
  }
}

class VoiceStrokesPainter extends CustomPainter {
  final List<double> strokeHeights;

  VoiceStrokesPainter(this.strokeHeights);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final width = size.width;
    final height = size.height;
    final strokeWidth = width / (strokeHeights.length * 2 - 1);

    for (int i = 0; i < strokeHeights.length; i++) {
      final x = i * strokeWidth * 2;
      final strokeHeight = strokeHeights[i] * height;
      canvas.drawLine(
        Offset(x, height / 2 - strokeHeight / 2),
        Offset(x, height / 2 + strokeHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(VoiceStrokesPainter oldDelegate) => true;
}
