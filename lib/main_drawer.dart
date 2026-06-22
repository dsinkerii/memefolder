import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/custom_tags_dialog.dart';
import 'package:memefolder/widgets/runtime_manager.dart';
import 'package:provider/provider.dart';

Widget buildDrawer(BuildContext context) {
  return Drawer(
    child: Column(
      children: [
        ListTile(
          leading: Icon(Icons.remove_red_eye),
          title: Text("toggle theme"),
          onTap: () {
            final toggle = !PlayerPrefs.getBool("isDarkMode", true);
            PlayerPrefs.setBool("isDarkMode", toggle);

            Provider.of<ThemeModel>(context, listen: false).dark = toggle;
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
      ],
    ),
  );
}
