import 'package:flutter/material.dart';

class MoveDialog extends StatefulWidget {
  const MoveDialog({
    super.key,
    required this.currentFolder,
    required this.folders,
    required this.title,
  });

  final String currentFolder;
  final List<String> folders;
  final String title;

  @override
  State<MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<MoveDialog> {
  late String _selectedFolder;
  final _newFolderCtrl = TextEditingController();
  bool _showNewFolderInput = false;

  @override
  void initState() {
    super.initState();
    _selectedFolder = widget.currentFolder;
  }

  @override
  void dispose() {
    _newFolderCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_showNewFolderInput)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.folders.length,
                  itemBuilder: (context, index) {
                    final folder = widget.folders[index];
                    return ListTile(
                      title: Text(folder),
                      trailing: _selectedFolder == folder ? const Icon(Icons.check) : null,
                      onTap: () {
                        setState(() => _selectedFolder = folder);
                      },
                    );
                  },
                ),
              ),
            if (_showNewFolderInput)
              TextField(
                controller: _newFolderCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'New Folder Name',
                  hintText: 'e.g. Work, Personal',
                ),
              ),
            TextButton.icon(
              onPressed: () {
                setState(() => _showNewFolderInput = !_showNewFolderInput);
              },
              icon: Icon(_showNewFolderInput ? Icons.list : Icons.add),
              label: Text(_showNewFolderInput ? 'Back to list' : 'Create new folder'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_showNewFolderInput) {
              final newName = _newFolderCtrl.text.trim();
              if (newName.isNotEmpty) {
                Navigator.pop(context, newName);
              }
            } else {
              Navigator.pop(context, _selectedFolder);
            }
          },
          child: const Text('Move'),
        ),
      ],
    );
  }
}
