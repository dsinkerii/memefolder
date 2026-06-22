import 'package:flutter/material.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/prefs.dart';
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
      ],
    ),
  );
}
