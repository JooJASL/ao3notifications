import 'dart:convert';

import 'package:ao3_scraper/ao3_scraper.dart';
import 'package:ao3notifications/helpers/change_username_dialog.dart';
import 'package:ao3notifications/helpers/updated_bookmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class Ao3Model extends ChangeNotifier {
  Ao3Model() {
    // initFuture = jad();
    initFuture = init();
  }

  /// initFuture is a variable meant to store the value of init().
  /// Then, in FutureBuilder, the future property is set to watch initFuture, which is final.
  /// This minimizes the rebuilds the app undergoes.
  late final Future<bool> initFuture;

  /// Initialized in Ao3Model.init()
  FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;

  String? _username;

  /// Username used to fetch the bookmarks.
  /// If its value changes, updateLibrary is automatically called.
  String get username {
    if (_username == null || _username!.isEmpty) {
      if (Hive.isBoxOpen("username") &&
          Hive.box<String>("username").isNotEmpty) {
        _username = Hive.box<String>("username").values.first;
      }
    }
    return _username ?? "";
  }

  set username(value) {
    _username = value;
    if (Hive.isBoxOpen("username")) {
      Hive.box<String>("username").put("username", _username ?? "");
    }

    // Clearing the bookmarks in memory, otherwise a notification will be sent
    // simply for changing to another username.
    bookmarks.clear();
    chapterTracker.clear();

    updateLibrary().whenComplete(() => notifyListeners());
  }

  /// Used by the updateLibrary() function to check if the database has already been read.
  /// Should always be true after the first call to updateLibrary().
  bool hasReadBookmarksInStorage = false;

  /// The Ao3 bookmarks in memory. Is populated by the updateLIbrary() function.
  var bookmarks = <Work>[];
  var notifications = <UpdatedBookmark>[];

  /// A map between workID and the chapterCount of the corresponding work.
  ///
  /// The updateLibrary() function will use this map to check if there has been an update.
  var chapterTracker = <int, int>{};

  /// Initializes the app's database as well as sets up
  /// local notifications.
  Future<bool> init() async {
    // Init
    await Hive.initFlutter();
    await Hive.openBox<String>("username");
    await Hive.openBox<int>("bookmarks");
    await Hive.openBox<String>("notifications");

    // Init local notifications plugin.
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const initializationSettingsAndroid =
        AndroidInitializationSettings('mipmap/ic_launcher');
    const initializationSettingsIOS = IOSInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );
    const initializationSettingsMacOS = MacOSInitializationSettings(
        requestBadgePermission: false, requestSoundPermission: false);
    const initializationSettingsLinux =
        LinuxInitializationSettings(defaultActionName: "Ao3");
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
      macOS: initializationSettingsMacOS,
      linux: initializationSettingsLinux,
    );
    final initializedProperly =
        await flutterLocalNotificationsPlugin!.initialize(
      initializationSettings,
      onSelectNotification: (payload) {},
    );

    if (initializedProperly != true) {
      throw (StateError(
          "Flutter local notifications plugin failed to initialize."));
    }

    // Getting the data into memory.
    updateLibrary();

    final _storedUpdates = Hive.box<String>("notifications").values;
    for (final update in _storedUpdates) {
      final notif = UpdatedBookmark.fromJson(jsonDecode(update));
      notifications.add(notif);
    }

    return true;
  }

  List<int> updateChapterTracker() {
    final updates = <int>[];

    for (final bookmark in bookmarks) {
      final oldChapterCount = chapterTracker[bookmark.workID];

      // If there has been no update.
      if (chapterTracker.containsKey(bookmark.workID) &&
          oldChapterCount == bookmark.numberOfChapters) {
        continue;
      }

      // If there has been an update: Update the chapterTracker and add the WorkID
      // of the updated bookmark into _newlyUpdated to be consumed.
      final _update = UpdatedBookmark(
        title: bookmark.title,
        author: bookmark.author,
        link: Ao3Client.getURLfromWorkID(bookmark.workID),
        updateCount: bookmark.numberOfChapters - (oldChapterCount ?? 0),
      );

      notifications.insert(0, _update);

      Hive.box<String>("notifications").add(jsonEncode(_update.toJson()));

      chapterTracker[bookmark.workID] = bookmark.numberOfChapters;
      updates.add(bookmark.workID);
    }

    return updates;
  }

  /// Updates the bookmarks list in the Ao3Model, as well as the
  /// chapterTracker map. If an update is found, it will immediately be
  /// consumed.
  ///
  /// It will automatically fetch the local database for bookmarks and updated the
  /// chapterTracker map with it for the sake of comparing it for new updates.
  Future<void> updateLibrary() async {
    // Read bookmarks in local storage on first app startup.
    if (hasReadBookmarksInStorage == false &&
        Hive.isBoxOpen("bookmarks") &&
        Hive.box<int>("bookmarks").isNotEmpty) {
      final _bookmarksBox = Hive.box<int>("bookmarks");

      // Getting the values in storage into the chapterTracker map,
      // so checking if there has been an update is easier.
      for (var i = 0; i < _bookmarksBox.length; i++) {
        final _workID = _bookmarksBox.keys.elementAt(i);
        final _chapterCount = _bookmarksBox.get(_workID);
        chapterTracker[_workID] = _chapterCount ?? 1;
      }

      hasReadBookmarksInStorage = true;
    }

    bookmarks = await Ao3Client.getBookmarksFromUsername(username);

    // Seeing what has been updated.
    var _newlyUpdated = updateChapterTracker();
    if (_newlyUpdated.isNotEmpty) consumeNotifications(_newlyUpdated.length);

    _updateBookmarksDatabase(bookmarks);

    notifyListeners();
  }

  Future<void> _updateBookmarksDatabase(bookmarks) async {
    if (Hive.isBoxOpen("bookmarks")) {
      // So that if a user has deleted a bookmark, it is reflected here.
      await Hive.box<int>("bookmarks").clear();

      for (final _work in bookmarks) {
        Hive.box<int>("bookmarks").put(_work.workID, _work.numberOfChapters);
      }
    }
  }

  /// consumeNotifications shows local notifications for the user that at least
  /// one of their bookmarks has received an updated.
  void consumeNotifications(int numOfUpdates) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails('0', 'bookmarks',
            channelDescription: 'Android channel for bookamrks.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ticker: 'ticker');
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await flutterLocalNotificationsPlugin!.show(0, 'Updates found.',
        '$numOfUpdates found in bookmarks.', platformChannelSpecifics,
        payload: 'bookmarks');
  }

  static void showChangeUsernameDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return const UsernameDialog();
      },
    );
  }

  static void ao3launchUrl(String _url) async {
    if (!await launchUrl(Uri.parse(_url))) throw 'Could not launch $_url';
  }
}
