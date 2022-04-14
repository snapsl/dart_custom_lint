import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/protocol/protocol_generated.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

import 'cli_test.dart';
import 'create_project.dart';
import 'matchers.dart';
import 'mock_fs.dart';
import 'run_plugin.dart';

void main() {
  test('List warnings for all files combined', () async {
    final plugin = createPlugin(
      name: 'test_lint',
      main: '''
import 'dart:isolate';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:custom_lint_builder/custom_lint_builder.dart';

void main(List<String> args, SendPort sendPort) {
  startPlugin(sendPort, _HelloWorldLint());
}

class _HelloWorldLint extends PluginBase {
  @override
  Iterable<Lint> getLints(LibraryElement library) sync* {
    for (final variable in library.topLevelElements) {
      yield Lint(
        code: 'hello_world',
        message: 'Hello world',
        location: LintLocation.fromOffsets(
          offset: variable.nameOffset,
          length: variable.nameLength,
        ),
      );
    }
  }
}
''',
    );

    final app = creatLintUsage(
      source: {
        'lib/main.dart': '''
void fn() {}

void fn2() {}
''',
        'lib/another.dart': 'void fn() {}\n',
      },
      plugins: {'test_lint': plugin.uri},
      name: 'test_app',
    );

    final lints = await runServerInCliModeForApp(app);

    expect(
      lints.map((e) => e.file),
      [
        join(app.path, 'lib', 'another.dart'),
        join(app.path, 'lib', 'main.dart'),
      ],
    );

    expect(
      lints.first.errors,
      [
        isA<AnalysisError>()
            .having((e) => e.code, 'code', 'hello_world')
            .having(
              (e) => e.location,
              'location',
              Location(
                join(app.path, 'lib', 'another.dart'),
                5,
                2,
                0,
                5,
                endLine: 0,
                endColumn: 7,
              ),
            )
            .having((e) => e.message, 'message', 'Hello world'),
      ],
    );
    expect(
      lints.last.errors,
      [
        isA<AnalysisError>()
            .having((e) => e.code, 'code', 'hello_world')
            .having(
              (e) => e.location,
              'location',
              Location(
                join(app.path, 'lib', 'main.dart'),
                5,
                2,
                0,
                5,
                endLine: 0,
                endColumn: 7,
              ),
            )
            .having((e) => e.message, 'message', 'Hello world'),
        isA<AnalysisError>()
            .having((e) => e.code, 'code', 'hello_world')
            .having(
              (e) => e.location,
              'location',
              Location(
                join(app.path, 'lib', 'main.dart'),
                19,
                3,
                2,
                5,
                endLine: 2,
                endColumn: 8,
              ),
            )
            .having((e) => e.message, 'message', 'Hello world'),
      ],
    );
  });

  test('supports running multiple plugins at once', () async {
    final plugin = createPlugin(name: 'test_lint', main: helloWordPluginSource);
    final plugin2 = createPlugin(name: 'test_lint2', main: oyPluginSource);

    final app = creatLintUsage(
      source: {
        'lib/main.dart': '''


void fn() {}''',
        'lib/another.dart': '''


void fn2() {}''',
      },
      plugins: {'test_lint': plugin.uri, 'test_lint2': plugin2.uri},
      name: 'test_app',
    );

    final lints = await runServerInCliModeForApp(app);

    expect(
      lints.map((e) => e.file),
      [
        join(app.path, 'lib', 'another.dart'),
        join(app.path, 'lib', 'main.dart'),
      ],
    );

    expect(
      lints.first.errors.map((e) => e.code),
      unorderedEquals(<Object?>['hello_world', 'oy']),
    );
    expect(
      lints.last.errors.map((e) => e.code),
      unorderedEquals(<Object?>['hello_world', 'oy']),
    );
  });

  test('redirect prints and errors to log files', () async {
    final plugin = createPlugin(
      name: 'test_lint',
      main: '''
import 'dart:isolate';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:custom_lint_builder/custom_lint_builder.dart';

void main(List<String> args, SendPort sendPort) {
  startPlugin(sendPort, _HelloWorldLint());
}

class _HelloWorldLint extends PluginBase {
  @override
  Iterable<Lint> getLints(LibraryElement library) sync* {
    if (library.topLevelElements.single.name == 'fail') {
       print('Hello world');
       throw StateError('fail');
    }
    yield Lint(
      code: 'hello_world',
      message: 'Hello world',
      location: LintLocation.fromOffsets(offset: 0, length: 1),
    );
  }
}
''',
    );
    final plugin2 = createPlugin(name: 'test_lint2', main: oyPluginSource);

    final app = creatLintUsage(
      source: {
        'lib/main.dart': 'void fn() {}\n',
        'lib/another.dart': 'void fail() {}\n',
      },
      plugins: {'test_lint': plugin.uri, 'test_lint2': plugin2.uri},
      name: 'test_app',
    );

    await runWithIOOverride((out, err) async {
      final runner = await startRunnerForApp(
        app,
        // Ignoring errors as we are handling them later
        ignoreErrors: true,
      );

      // Plugin errors will be emitted as notifications, not as part of the response
      expect(runner.channel.responseErrors, emitsDone);

      // The error in our plugin will be reported as PluginErrorParams
      expect(
        runner.channel.pluginErrors.toList(),
        completion([
          predicate<PluginErrorParams>((value) {
            expect(
              value.message,
              'The following exception was thrown while trying to obtain lints for ${app.path}/lib/another.dart:\n'
              'Bad state: fail',
            );
            return true;
          }),
          // Since we are using getLints(), the lints will be requested twice per
          // Dart file. So the error will be thrown twice
          predicate<PluginErrorParams>((value) {
            expect(
              value.message,
              'The following exception was thrown while trying to obtain lints for ${app.path}/lib/another.dart:\n'
              'Bad state: fail',
            );
            return true;
          }),
        ]),
      );

      final lints = await runner.getLints();

      expect(
        lints.map((e) => e.file),
        [
          join(app.path, 'lib', 'another.dart'),
          join(app.path, 'lib', 'main.dart'),
        ],
      );

      expect(
        lints.first.errors.map((e) => e.code),
        unorderedEquals(<Object?>['oy']),
      );
      expect(
        lints.last.errors.map((e) => e.code),
        unorderedEquals(<Object?>['hello_world', 'oy']),
      );

      expect(
        app.log,
        matchesLogGolden(
          'test/goldens/server_test/redirect_logs.log',
          paths: {plugin.uri: 'plugin', app.uri: 'app'},
        ),
      );

      // Closing so that previous error matchers relying on stream
      // closing can complete
      await runner.close();
    });
  });

  group('hot-restart', () {
    test('handles the source change of one plugin and restart it', () async {
      final plugin = createPlugin(
        name: 'test_lint',
        main: helloWordPluginSource,
      );
      final plugin2 = createPlugin(name: 'test_lint2', main: oyPluginSource);

      final app = creatLintUsage(
        source: {'lib/main.dart': 'void fn() {}\n'},
        plugins: {'test_lint': plugin.uri, 'test_lint2': plugin2.uri},
        name: 'test_app',
      );

      final runner = await startRunnerForApp(app);

      await expectLater(
        runner.channel.lints,
        emitsInOrder(<Object?>[
          predicate<AnalysisErrorsParams>((value) {
            expect(value.file, join(app.path, 'lib', 'main.dart'));
            expect(value.errors.single.code, anyOf('hello_world', 'oy'));
            return true;
          }),
          predicate<AnalysisErrorsParams>((value) {
            expect(value.file, join(app.path, 'lib', 'main.dart'));
            expect(
              value.errors.map((e) => e.code),
              unorderedEquals(<Object?>['hello_world', 'oy']),
            );
            return true;
          }),
        ]),
      );

      plugin.pluginMain.writeAsStringSync('''
import 'dart:isolate';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:custom_lint_builder/custom_lint_builder.dart';

void main(List<String> args, SendPort sendPort) {
  startPlugin(sendPort, _ReloaddLint());
}

class _ReloaddLint extends PluginBase {
  @override
  Iterable<Lint> getLints(LibraryElement library) sync* {
    yield Lint(
      code: 'hello_reload',
      message: 'Hello reload',
      location: LintLocation.fromOffsets(
        offset: library.topLevelElements.first.nameOffset,
        length: library.topLevelElements.first.nameLength,
      ),
    );
  }
}
''');

      await expectLater(
        runner.channel.lints,
        emitsInOrder(<Object?>[
          predicate<AnalysisErrorsParams>((value) {
            expect(value.file, join(app.path, 'lib', 'main.dart'));
            // Clears lints previously emitted by the reloaded plugin
            expect(value.errors.single.code, 'oy');
            return true;
          }),
          predicate<AnalysisErrorsParams>((value) {
            expect(value.file, join(app.path, 'lib', 'main.dart'));
            expect(
              value.errors.map((e) => e.code),
              unorderedEquals(<Object?>['hello_reload', 'oy']),
            );
            return true;
          }),
        ]),
      );

      expect(runner.channel.lints, emitsDone);

      // Closing so that previous error matchers relying on stream
      // closing can complete
      await runner.close();

      expect(plugin.log.existsSync(), false);
      expect(plugin2.log.existsSync(), false);
    });

    test('supports reloading a working plugin into one that fails', () async {
      final plugin = createPlugin(
        name: 'test_lint',
        main: helloWordPluginSource,
      );
      final plugin2 = createPlugin(name: 'test_lint2', main: oyPluginSource);

      final app = creatLintUsage(
        source: {'lib/main.dart': 'void fn() {}\n'},
        plugins: {'test_lint': plugin.uri, 'test_lint2': plugin2.uri},
        name: 'test_app',
      );

      await runWithIOOverride((out, err) async {
        final runner = await startRunnerForApp(app, ignoreErrors: true);

        await expectLater(
          runner.channel.lints,
          emitsInOrder(<Object?>[
            predicate<AnalysisErrorsParams>((value) {
              expect(value.file, join(app.path, 'lib', 'main.dart'));
              expect(value.errors.single.code, anyOf('hello_world', 'oy'));
              return true;
            }),
            predicate<AnalysisErrorsParams>((value) {
              expect(value.file, join(app.path, 'lib', 'main.dart'));
              expect(
                value.errors.map((e) => e.code),
                unorderedEquals(<Object?>['hello_world', 'oy']),
              );
              return true;
            }),
          ]),
        );

        expect(plugin.log.existsSync(), false);
        expect(plugin2.log.existsSync(), false);

        plugin.pluginMain.writeAsStringSync('''
invalid;
''');

        // Plugin errors will be emitted as notifications, not as part of the response
        expect(runner.channel.responseErrors, emitsDone);

        // The error in our plugin will be reported as PluginErrorParams
        // We don't immediately await it, as we could otherwise miss the lint update

        final awaitError = expectLater(
          runner.channel.pluginErrors,
          emits(
            isA<PluginErrorParams>().having((e) => e.message, 'message', '''
IsolateSpawnException: Unable to spawn isolate: ${plugin.path}/bin/custom_lint.dart:1:1: \x1B[31mError: Variables must be declared using the keywords 'const', 'final', 'var' or a type name.
Try adding the name of the type of the variable or the keyword 'var'.\x1B[39;49m
invalid;
^^^^^^^'''),
          ),
        );
        await expectLater(
          runner.channel.lints,
          emits(
            predicate<AnalysisErrorsParams>((value) {
              expect(value.file, join(app.path, 'lib', 'main.dart'));
              // Clears lints previously emitted by the reloaded plugin
              expect(value.errors.single.code, 'oy');
              return true;
            }),
          ),
        );

        await awaitError;

        expect(runner.channel.pluginErrors, emitsDone);
        expect(runner.channel.lints, emitsDone);

        // Closing so that previous error matchers relying on stream
        // closing can complete
        await runner.close();

        expect(plugin.log.existsSync(), false);
        expect(plugin2.log.existsSync(), false);
      });
    });
  });
}
