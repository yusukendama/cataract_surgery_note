import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

const appSupportedLocales = <Locale>[Locale('ja')];

const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// The app is currently Japanese-only, including on non-Japanese devices.
Locale resolveAppLocale(Locale? _, Iterable<Locale> _) => const Locale('ja');
