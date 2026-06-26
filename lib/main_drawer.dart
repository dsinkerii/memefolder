import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:memefolder/widgets/custom_tags_dialog.dart';
import 'package:memefolder/widgets/runtime_manager.dart';
import 'package:memefolder/widgets/settings_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

Widget buildDrawer(BuildContext context) {
  return Drawer(
    child: Column(
      children: [
        Padding(
          padding: .all(20),
          child: Image(image: ExactAssetImage('Assets/Images/CroppedLogo.png')),
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.settings),
          title: Text("settings"),
          onTap: () {
            Navigator.of(context).pop();
            showSettingsDialog(context);
          },
        ),
        ListTile(
          leading: Icon(MaterialCommunityIcons.tag_text),
          title: Text("custom tags"),
          onTap: () {
            Navigator.of(context).pop();
            showCustomTagsDialog(context);
          },
        ),
        ListTile(
          leading: Icon(Ionicons.hardware_chip_sharp),
          title: Text("runtime manager"),
          onTap: () {
            Navigator.of(context).pop();
            showRuntimeManagerDialog(context);
          },
        ),
        Spacer(),
        ListTile(
          leading: Icon(Zocial.github),
          title: Text("github page"),
          onTap: () {
            Navigator.of(context).pop();
            _openLink("https://github.com/dsinkerii/memefolder");
          },
        ),
        ListTile(
          leading: Icon(Icons.attach_money),
          title: Text("support me"),
          onTap: () {
            Navigator.of(context).pop();

            showBubble(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AntDesign.smile_circle, color: Colors.white),
                  const SizedBox(width: 12),
                  Text(
                    "thank you",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                    softWrap: true,
                  ),
                ],
              ),
            );
            _openLink("https://boosty.to/dsinkerii");
          },
        ),
      ],
    ),
  );
}

void _openLink(String url) async {
  final Uri _url = Uri.parse(url);

  if (!await launchUrl(_url)) {
    throw Exception('Could not launch $_url');
  }
}
