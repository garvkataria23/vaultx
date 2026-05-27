import 'package:flutter_gemma/flutter_gemma.dart';

class LLMChatService {
  LLMChatService._();
  static final LLMChatService instance = LLMChatService._();

  static const String _modelUrl =
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm';
  static const String _modelFilename = 'Qwen3-0.6B.litertlm';

  bool _initialized = false;
  bool _modelInstalled = false;
  InferenceModel? _model;

  bool get isAvailable => _initialized && _modelInstalled && _model != null;

  Future<void> initialize() async {
    if (_initialized) return;
    FlutterGemma.initialize();
    _modelInstalled = await FlutterGemma.isModelInstalled(_modelFilename);
    if (_modelInstalled) {
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );
    }
    _initialized = true;
  }

  Future<void> installModel({void Function(int progress)? onProgress}) async {
    if (!_initialized) {
      FlutterGemma.initialize();
      _initialized = true;
    }
    await FlutterGemma.installModel(
          modelType: ModelType.qwen3,
          fileType: ModelFileType.litertlm,
        )
        .fromNetwork(_modelUrl, foreground: true)
        .withProgress(onProgress ?? (_) {})
        .install();
    _modelInstalled = true;
    _model = await FlutterGemma.getActiveModel(
      maxTokens: 2048,
      preferredBackend: PreferredBackend.gpu,
    );
  }

  Future<String> generateResponse(String query) async {
    if (!isAvailable) return '';
    try {
      final chat = await _model!.createChat();
      await chat.addQueryChunk(Message.text(text: query, isUser: true));
      final response = await chat.generateChatResponse();
      return switch (response) {
        TextResponse r => r.token,
        FunctionCallResponse r => 'Function call: ${r.name}(${r.args})',
        ParallelFunctionCallResponse r => 'Parallel function calls: ${r.calls.map((c) => '${c.name}(${c.args})').join(', ')}',
        ThinkingResponse r => r.content,
      };
    } catch (e) {
      return 'Sorry, I encountered an error: $e';
    }
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _initialized = false;
    _modelInstalled = false;
  }
}
