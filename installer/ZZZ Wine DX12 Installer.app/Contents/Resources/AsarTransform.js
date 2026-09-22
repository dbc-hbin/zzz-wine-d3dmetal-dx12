(function () {
  "use strict";

  function staticPropertyName(name) {
    return ts.isIdentifier(name) || ts.isStringLiteralLike(name) ? name.text : undefined;
  }

  function property(object, name) {
    return object.properties.find(function (item) {
      return ts.isPropertyAssignment(item) && staticPropertyName(item.name) === name;
    });
  }

  function stringLiteralValue(node) {
    return ts.isStringLiteralLike(node) ? node.text : undefined;
  }

  function visit(node, callback) {
    callback(node);
    ts.forEachChild(node, function (child) { visit(child, callback); });
  }

  function wineDistribution(node) {
    if (!ts.isObjectLiteralExpression(node)) return undefined;
    var id = property(node, "id");
    var displayName = property(node, "displayName");
    var remoteUrl = property(node, "remoteUrl");
    var attributes = property(node, "attributes");
    if (!id || !displayName || !remoteUrl || !attributes || !ts.isObjectLiteralExpression(attributes.initializer)) return undefined;
    var renderBackend = property(attributes.initializer, "renderBackend");
    if (!renderBackend || stringLiteralValue(id.initializer) === undefined || stringLiteralValue(displayName.initializer) === undefined || stringLiteralValue(remoteUrl.initializer) === undefined || stringLiteralValue(renderBackend.initializer) === undefined) return undefined;
    return { id: stringLiteralValue(id.initializer), renderBackend: stringLiteralValue(renderBackend.initializer), node: node };
  }

  function parse(source) {
    var sourceFile = ts.createSourceFile("frontend.js", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    if (sourceFile.parseDiagnostics.length) throw new Error(ts.flattenDiagnosticMessageText(sourceFile.parseDiagnostics[0].messageText, "\n"));
    return sourceFile;
  }

  function text(node, sourceFile) {
    return node.getText(sourceFile);
  }

  function applyChanges(source, changes) {
    changes.sort(function (left, right) { return right.start - left.start; });
    var end = source.length;
    var output = source;
    for (var index = 0; index < changes.length; index += 1) {
      var change = changes[index];
      if (change.end > end) throw new Error("overlapping structural source changes");
      output = output.slice(0, change.start) + change.replacement + output.slice(change.end);
      end = change.start;
    }
    return output;
  }

  function propertyAccessName(node) {
    return ts.isPropertyAccessExpression(node) ? node.name.text : undefined;
  }

  function isIdentifierNamed(node, name) {
    return ts.isIdentifier(node) && node.text === name;
  }

  function findTargetDistribution(sourceFile, targetId) {
    var distributions = [];
    visit(sourceFile, function (node) {
      var distribution = wineDistribution(node);
      if (distribution) distributions.push(distribution);
    });
    var targets = distributions.filter(function (distribution) { return distribution.id === targetId; });
    if (targets.length > 1) throw new Error("Wine distribution id is duplicated: " + targetId);
    return { distributions: distributions, target: targets[0] };
  }

  function catalogArray(distributions) {
    var candidates = new Map();
    distributions.forEach(function (distribution) {
      var parent = distribution.node.parent;
      if (!ts.isArrayLiteralExpression(parent)) return;
      var candidate = candidates.get(parent);
      if (!candidate) {
        candidate = { array: parent, count: 0 };
        candidates.set(parent, candidate);
      }
      candidate.count += 1;
    });
    var values = Array.from(candidates.values());
    if (!values.length) throw new Error("could not locate the Wine distribution catalog array");
    values.sort(function (left, right) { return right.count - left.count; });
    if (values.length > 1 && values[0].count === values[1].count) throw new Error("Wine distribution catalog array is ambiguous");
    return values[0].array;
  }

  function functionNodes(sourceFile) {
    var functions = [];
    visit(sourceFile, function (node) {
      if (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node)) functions.push(node);
    });
    return functions;
  }

  function findStreamingDownload(functionNode) {
    var matches = [];
    visit(functionNode.body, function (node) {
      if (!ts.isForOfStatement(node) || !node.awaitModifier) return;
      var download;
      visit(node.expression, function (child) {
        if (!ts.isCallExpression(child) || propertyAccessName(child.expression) !== "doStreamingDownload") return;
        download = child;
      });
      if (download) matches.push({ loop: node, download: download });
    });
    if (matches.length !== 1) throw new Error("could not unambiguously locate the Wine streaming download");
    return matches[0];
  }

  function wineIdentifierFromDownload(download) {
    var argument = download.arguments[0];
    if (!argument || !ts.isObjectLiteralExpression(argument)) throw new Error("Wine streaming download has no object options");
    var uri = property(argument, "uri");
    if (!uri || !ts.isPropertyAccessExpression(uri.initializer) || uri.initializer.name.text !== "remoteUrl" || !ts.isIdentifier(uri.initializer.expression)) throw new Error("Wine streaming download does not use a distribution URL");
    return uri.initializer.expression.text;
  }

  function installFunction(sourceFile) {
    var matches = functionNodes(sourceFile).filter(function (candidate) {
      if (!candidate.body) return false;
      var bodyText = text(candidate.body, sourceFile);
      return bodyText.includes("doStreamingDownload") && bodyText.includes("wine_state") && bodyText.includes("wine_tag") && bodyText.includes("./wine.tar.");
    });
    if (!matches.length) throw new Error("could not locate the Wine installation function");
    matches.sort(function (left, right) { return left.end - left.pos - (right.end - right.pos); });
    return matches[0];
  }

  function localInstallerChanges(sourceFile, targetId, protectedRuntimeIds) {
    var functionNode = installFunction(sourceFile);
    var bodyText = text(functionNode.body, sourceFile);
    if (bodyText.includes("__yaaglD3MetalLocalArchive")) {
      var markers = [];
      visit(functionNode.body, function (node) {
        if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.name.text === "__yaaglD3MetalLocalArchive" && node.initializer) markers.push(node.initializer);
      });
      if (markers.length !== 1) throw new Error("could not unambiguously locate prior local Wine archive marker");
      var wine = wineIdentifierFromDownload(findStreamingDownload(functionNode).download);
      var protectedIds = JSON.stringify(protectedRuntimeIds);
      var replacement = protectedIds + ".includes(" + wine + ".id)&&" + wine + ".remoteUrl.startsWith(\"file:\")";
      var markerText = text(markers[0], sourceFile);
      if (markerText.includes(protectedIds + ".includes(" + wine + ".id)") && markerText.includes(wine + ".remoteUrl.startsWith(\"file:\")")) return [];
      return [{ start: markers[0].getStart(sourceFile), end: markers[0].end, replacement: replacement }];
    }

    var streaming = findStreamingDownload(functionNode);
    var wine = wineIdentifierFromDownload(streaming.download);
    if (bodyText.includes("archiveSha256") && bodyText.includes("kind===\"local\"")) {
      return bodyText.includes(targetId) ? [] : legacyLocalInstallerChanges(functionNode, sourceFile, wine, targetId);
    }
    var declarationLists = [];
    visit(functionNode.body, function (node) {
      if (ts.isVariableDeclarationList(node) && (node.flags & ts.NodeFlags.Const)) declarationLists.push(node);
    });
    var declarations = declarationLists.filter(function (list) {
      if (list.declarations.length !== 2) return false;
      var hasCompressedUrl = false;
      var hasArchivePath = false;
      list.declarations.forEach(function (declaration) {
        if (!ts.isIdentifier(declaration.name) || !declaration.initializer) return;
        var initializerText = text(declaration.initializer, sourceFile);
        hasCompressedUrl = hasCompressedUrl || initializerText.includes(wine + ".remoteUrl.endsWith(\".xz\")");
        hasArchivePath = hasArchivePath || initializerText.includes("./wine.tar.");
      });
      return hasCompressedUrl && hasArchivePath;
    });
    if (declarations.length !== 1) throw new Error("could not unambiguously locate the Wine archive declarations");

    var declarationList = declarations[0];
    var compressed = declarationList.declarations.find(function (declaration) {
      return declaration.initializer && text(declaration.initializer, sourceFile).includes(wine + ".remoteUrl.endsWith(\".xz\")");
    });
    var archive = declarationList.declarations.find(function (declaration) {
      return declaration.initializer && text(declaration.initializer, sourceFile).includes("./wine.tar.");
    });
    if (!compressed || !archive || !ts.isIdentifier(compressed.name) || !ts.isIdentifier(archive.name) || !compressed.initializer || !archive.initializer) throw new Error("Wine archive declarations have an unsupported shape");

    var marker = "__yaaglD3MetalLocalArchive";
    var protectedIds = JSON.stringify(protectedRuntimeIds);
    var declarationReplacement = "let " + compressed.name.text + "=" + text(compressed.initializer, sourceFile) + "," + marker + "=" + protectedIds + ".includes(" + wine + ".id)&&" + wine + ".remoteUrl.startsWith(\"file:\")," + archive.name.text + "=" + marker + "?decodeURIComponent(new URL(" + wine + ".remoteUrl).pathname):" + text(archive.initializer, sourceFile);

    var deletes = [];
    visit(functionNode.body, function (node) {
      if (!ts.isAwaitExpression(node)) return;
      var expression = node.expression;
      if (!ts.isCallExpression(expression) || expression.arguments.length !== 1 || !isIdentifierNamed(expression.arguments[0], archive.name.text)) return;
      deletes.push(node);
    });
    if (deletes.length !== 1) throw new Error("could not unambiguously locate temporary Wine archive removal");

    var extractionArchives = [];
    visit(functionNode.body, function (node) {
      if (!ts.isCallExpression(node) || !ts.isCallExpression(node.parent)) return;
      if (text(node, sourceFile).includes("./wine.tar.")) extractionArchives.push(node);
    });
    if (extractionArchives.length !== 2) throw new Error("could not unambiguously locate Wine archive extraction arguments");

    return [
      { start: declarationList.getStart(sourceFile), end: declarationList.end, replacement: declarationReplacement },
      { start: streaming.loop.getStart(sourceFile), end: streaming.loop.end, replacement: "if(!" + marker + ")" + text(streaming.loop, sourceFile) },
      { start: deletes[0].getStart(sourceFile), end: deletes[0].end, replacement: "!" + marker + "&&" + text(deletes[0], sourceFile) }
    ].concat(extractionArchives.map(function (argument) {
      return { start: argument.getStart(sourceFile), end: argument.end, replacement: archive.name.text };
    }));
  }

  function legacyLocalInstallerChanges(functionNode, sourceFile, wine, targetId) {
    var localKinds = [];
    visit(functionNode.body, function (node) {
      if (!ts.isVariableDeclaration(node) || !node.initializer || !ts.isIdentifier(node.name)) return;
      if (!ts.isCallExpression(node.initializer) || node.initializer.arguments.length !== 1) return;
      var argument = node.initializer.arguments[0];
      if (ts.isPropertyAccessExpression(argument) && argument.name.text === "remoteUrl" && isIdentifierNamed(argument.expression, wine)) localKinds.push(node.name.text);
    });
    if (localKinds.length !== 1) throw new Error("could not unambiguously locate prior local Wine URL handling");
    var localKind = localKinds[0];
    var checks = [];
    visit(functionNode.body, function (node) {
      if (!ts.isIfStatement(node)) return;
      var condition = text(node.expression, sourceFile);
      var statement = text(node.thenStatement, sourceFile);
      if (condition.includes("archiveSha256") || (condition.includes(localKind + ".kind===\"local\"") && statement.includes("inside a directory being replaced"))) checks.push(node);
    });
    if (checks.length !== 3) throw new Error("could not unambiguously locate prior local Wine validation");
    var target = JSON.stringify(targetId);
    return checks.map(function (check) {
      return {
        start: check.expression.getStart(sourceFile),
        end: check.expression.end,
        replacement: "(" + text(check.expression, sourceFile) + ")&&" + wine + ".id!==" + target
      };
    });
  }

  function removePriorCatalogValidation(sourceFile, targetNode) {
    var container = targetNode;
    while (container && !ts.isFunctionDeclaration(container) && !ts.isFunctionExpression(container) && !ts.isArrowFunction(container)) container = container.parent;
    if (!container || !container.body || !ts.isBlock(container.body)) return [];
    var statements = container.body.statements;
    var returnIndex = -1;
    for (var index = 0; index < statements.length; index += 1) {
      if (ts.isReturnStatement(statements[index]) && statements[index].getStart(sourceFile) <= targetNode.getStart(sourceFile) && statements[index].end >= targetNode.end) returnIndex = index;
    }
    if (returnIndex <= 0 || returnIndex !== statements.length - 1 || !text(container.body, sourceFile).includes("archiveSha256")) return [];
    var prior = [];
    for (var position = 0; position < returnIndex; position += 1) {
      var statement = statements[position];
      if (!ts.isVariableStatement(statement) && !ts.isIfStatement(statement)) return [];
      prior.push({ start: statement.getStart(sourceFile), end: statement.end, replacement: "" });
    }
    return prior;
  }

  function launchChanges(sourceFile) {
    var matches = functionNodes(sourceFile).filter(function (candidate) {
      if (!candidate.body) return false;
      var bodyText = text(candidate.body, sourceFile);
      return bodyText.includes("resolutionCustom") && bodyText.includes(".setProps(") && bodyText.includes("GAME_RUNNING");
    });
    if (matches.length !== 1) throw new Error("could not unambiguously locate the game launch function");
    var functionNode = matches[0];

    var wineCalls = [];
    visit(functionNode.body, function (node) {
      if (ts.isCallExpression(node) && propertyAccessName(node.expression) === "setProps" && ts.isIdentifier(node.expression.expression)) wineCalls.push(node.expression.expression.text);
    });
    if (wineCalls.length !== 1) throw new Error("could not unambiguously locate the game Wine instance");

    var variables = [];
    visit(functionNode.body, function (node) {
      if (!ts.isVariableStatement(node) || node.declarationList.declarations.length !== 1) return;
      var declaration = node.declarationList.declarations[0];
      if (ts.isIdentifier(declaration.name) && declaration.initializer && ts.isArrayLiteralExpression(declaration.initializer) && declaration.initializer.elements.length === 0) variables.push({ statement: node, name: declaration.name.text });
    });
    if (variables.length !== 1) throw new Error("could not unambiguously locate game launch arguments");

    var wine = wineCalls[0];
    var argumentsName = variables[0].name;
    var d3d12Statements = [];
    visit(functionNode.body, function (node) {
      if (!ts.isExpressionStatement(node)) return;
      var expression = node.expression;
      while (ts.isBinaryExpression(expression) && expression.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) expression = expression.right;
      if (ts.isCallExpression(expression) && expression.arguments.length === 1 && stringLiteralValue(expression.arguments[0]) === "-use-d3d12" && propertyAccessName(expression.expression) === "push" && isIdentifierNamed(expression.expression.expression, argumentsName)) d3d12Statements.push(node);
    });

    var configBindings = [];
    functionNode.parameters.forEach(function (parameter) {
      if (!ts.isObjectBindingPattern(parameter.name)) return;
      parameter.name.elements.forEach(function (element) {
        var propertyName = element.propertyName ? staticPropertyName(element.propertyName) : staticPropertyName(element.name);
        if (propertyName === "config" && ts.isIdentifier(element.name)) configBindings.push(element.name.text);
      });
    });
    if (configBindings.length !== 1) throw new Error("could not unambiguously locate the game launch config");

    var config = configBindings[0];
    var d3d12Statement = config + ".useD3D12&&" + wine + ".attributes.supportsD3d12===true&&" + argumentsName + ".push(\"-use-d3d12\");";
    var changes = d3d12Statements.length ? [{
      start: d3d12Statements[0].getStart(sourceFile),
      end: d3d12Statements[0].end,
      replacement: d3d12Statement
    }] : [{
      start: variables[0].statement.end,
      end: variables[0].statement.end,
      replacement: d3d12Statement
    }];
    d3d12Statements.slice(1).forEach(function (statement) {
      changes.push({ start: statement.getStart(sourceFile), end: statement.end, replacement: "" });
    });

    var steamBranches = [];
    visit(functionNode.body, function (node) {
      if (!ts.isConditionalExpression(node) || !ts.isPropertyAccessExpression(node.condition) || node.condition.name.text !== "steamPatch" || !ts.isArrayLiteralExpression(node.whenTrue)) return;
      var first = node.whenTrue.elements[0];
      if (!first || !ts.isCallExpression(first) || propertyAccessName(first.expression) !== "toWinePath" || !isIdentifierNamed(first.expression.expression, wine)) return;
      steamBranches.push(node.whenTrue);
    });
    if (steamBranches.length !== 1) throw new Error("could not unambiguously locate the Steam game launch arguments");
    var steamArguments = steamBranches[0];
    var forwardsGameArguments = steamArguments.elements.some(function (element) {
      return ts.isSpreadElement(element) && isIdentifierNamed(element.expression, argumentsName);
    });
    if (!forwardsGameArguments) {
      changes.push({
        start: steamArguments.end - 1,
        end: steamArguments.end - 1,
        replacement: ",..." + argumentsName
      });
    }
    return changes;
  }

  function precomposedD3DMetalChanges(sourceFile) {
    var matches = [];
    visit(sourceFile, function (node) {
      if (!ts.isBinaryExpression(node) || node.operatorToken.kind !== ts.SyntaxKind.AmpersandAmpersandToken) return;
      var condition = text(node.left, sourceFile);
      var action = text(node.right, sourceFile);
      if (!condition.includes(".attributes.renderBackend") || !condition.includes("d3dmetal") || !action.includes("yield*")) return;
      var wines = [];
      visit(node.left, function (candidate) {
        if (!ts.isPropertyAccessExpression(candidate) || candidate.name.text !== "renderBackend") return;
        var attributes = candidate.expression;
        if (ts.isPropertyAccessExpression(attributes) && attributes.name.text === "attributes") wines.push(attributes.expression);
      });
      if (wines.length !== 1) throw new Error("could not identify the D3DMetal overlay Wine object");
      matches.push({ condition: node.left, wine: text(wines[0], sourceFile) });
    });
    return matches.flatMap(function (match) {
      var condition = text(match.condition, sourceFile);
      if (condition.includes(".attributes.precomposedD3DMetal")) return [];
      return [{
        start: match.condition.getStart(sourceFile),
        end: match.condition.end,
        replacement: "(" + condition + ")&&" + match.wine + ".attributes.precomposedD3DMetal!==true"
      }];
    });
  }

  function findUpdaterCommitMove(sourceFile) {
    var matches = [];
    visit(sourceFile, function (node) {
      if (ts.isCallExpression(node) && node.arguments.length >= 2) {
        var a0 = stringLiteralValue(node.arguments[0]);
        var a1 = stringLiteralValue(node.arguments[1]);
        if (a0 === "./resources.neu.update" && a1 === "./resources.neu") {
          matches.push(node);
        }
      }
    });
    if (matches.length === 0) throw new Error("could not locate supported Yaagl updater in frontend bundle");
    if (matches.length > 1) throw new Error("could not unambiguously locate supported Yaagl updater in frontend bundle");
    return matches[0];
  }

  function discoverExecAndResolve(sourceFile, calleeName) {
    var declarations = [];
    visit(sourceFile, function (node) {
      if (ts.isFunctionDeclaration(node) && node.name && node.name.text === calleeName) {
        declarations.push(node);
      }
    });
    if (declarations.length === 0) throw new Error("could not locate updater move function declaration: " + calleeName);
    if (declarations.length > 1) throw new Error("updater move function declaration is ambiguous: " + calleeName);
    var calleeDecl = declarations[0];

    var mvCalls = [];
    visit(calleeDecl, function (node) {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.arguments.length >= 1 && ts.isArrayLiteralExpression(node.arguments[0])) {
        var arr = node.arguments[0];
        var hasMv = arr.elements.some(function (el) { return stringLiteralValue(el) === "mv"; });
        if (hasMv) mvCalls.push({ call: node, arr: arr });
      }
    });

    if (mvCalls.length === 0) throw new Error("could not locate move command in updater helper");
    if (mvCalls.length > 1) throw new Error("multiple move commands in updater helper are ambiguous");

    var moveCall = mvCalls[0];
    var execIdent = moveCall.call.expression.text;
    var resolves = [];
    moveCall.arr.elements.forEach(function (el) {
      visit(el, function (sub) {
        if (ts.isCallExpression(sub) && ts.isIdentifier(sub.expression)) {
          resolves.push(sub.expression.text);
        }
      });
    });

    if (resolves.length < 2) throw new Error("could not locate source and destination path resolution in updater move command");
    var firstResolve = resolves[0];
    for (var index = 1; index < resolves.length; index += 1) {
      if (resolves[index] !== firstResolve) {
        throw new Error("inconsistent path resolution helpers in updater move command: " + firstResolve + " vs " + resolves[index]);
      }
    }

    return { execIdent: execIdent, resolveIdent: firstResolve };
  }

  function recognizeUpdaterWrapper(moveCall, sourceFile) {
    var awaitNode = moveCall.parent;
    if (!ts.isAwaitExpression(awaitNode)) return undefined;
    var binary = awaitNode.parent;
    if (!ts.isBinaryExpression(binary) || binary.operatorToken.kind !== ts.SyntaxKind.CommaToken || binary.right !== awaitNode) {
      return undefined;
    }
    var leftBinary = binary.left;
    if (!ts.isBinaryExpression(leftBinary) || leftBinary.operatorToken.kind !== ts.SyntaxKind.CommaToken) {
      return undefined;
    }
    var assignExpr = leftBinary.left;
    var helperAwait = leftBinary.right;
    if (!ts.isAwaitExpression(helperAwait) || !ts.isCallExpression(helperAwait.expression)) return undefined;
    if (!text(assignExpr, sourceFile).includes("__yaaglD3MetalUpdate")) return undefined;

    var root = binary;
    if (root.parent && ts.isParenthesizedExpression(root.parent)) {
      root = root.parent;
    }
    return {
      wrapperNode: root,
      helperCall: helperAwait.expression,
      moveAwait: awaitNode
    };
  }

  function updaterChanges(sourceFile, options) {
    var marker = "__yaaglD3MetalUpdate";
    var sourceText = sourceFile.text;
    var moveCall = findUpdaterCommitMove(sourceFile);
    var calleeName = ts.isIdentifier(moveCall.expression) ? moveCall.expression.text : undefined;
    if (!calleeName) throw new Error("updater commit move callee is not an identifier");

    var discovered = discoverExecAndResolve(sourceFile, calleeName);
    var updatePathExpr = discovered.resolveIdent + "(\"./resources.neu.update\")";
    var helperCall = discovered.execIdent + "([" +
      JSON.stringify(options.registrationHelperPath) + ",\"--resource-path\"," +
      updatePathExpr + ",\"--archive-path\"," +
      JSON.stringify(options.archivePath) + "])";

    var existingWrapper = recognizeUpdaterWrapper(moveCall, sourceFile);
    if (existingWrapper) {
      var callArgs = existingWrapper.helperCall.arguments;
      if (callArgs.length === 1 && ts.isArrayLiteralExpression(callArgs[0])) {
        var elements = callArgs[0].elements;
        if (elements.length === 5 &&
            stringLiteralValue(elements[0]) === options.registrationHelperPath &&
            stringLiteralValue(elements[4]) === options.archivePath) {
          return [];
        }
      }
      var moveAwaitText = text(existingWrapper.moveAwait, sourceFile);
      var replacement = "(globalThis." + marker + "=true,await " + helperCall + "," + moveAwaitText + ")";
      return [{
        start: existingWrapper.wrapperNode.getStart(sourceFile),
        end: existingWrapper.wrapperNode.end,
        replacement: replacement
      }];
    }

    if (sourceText.includes(marker)) {
      throw new Error("unrecognized or corrupt " + marker + " hook present in frontend bundle");
    }

    var awaitNode = moveCall.parent;
    if (!ts.isAwaitExpression(awaitNode)) throw new Error("updater commit move is not awaited");

    var originalAwaitText = text(awaitNode, sourceFile);
    var replacement = "(globalThis." + marker + "=true,await " + helperCall + "," + originalAwaitText + ")";

    return [{
      start: awaitNode.getStart(sourceFile),
      end: awaitNode.end,
      replacement: replacement
    }];
  }

  globalThis.__asarRecoverRegistration = function (source, targetId) {
    try {
      var sourceFile = parse(source);
      var moveCall = findUpdaterCommitMove(sourceFile);
      var wrapper = recognizeUpdaterWrapper(moveCall, sourceFile);
      if (!wrapper) throw new Error("Cannot recover an unrecognized registration hook; current resources were preserved");
      var binary = wrapper.moveAwait.parent;
      var assignment = binary.left.left;
      var discovered = discoverExecAndResolve(sourceFile, moveCall.expression.text);
      var call = wrapper.helperCall;
      var args = call.arguments.length === 1 && ts.isArrayLiteralExpression(call.arguments[0]) ? call.arguments[0].elements : [];
      if (!ts.isBinaryExpression(assignment) || assignment.operatorToken.kind !== ts.SyntaxKind.EqualsToken ||
          !ts.isPropertyAccessExpression(assignment.left) || !isIdentifierNamed(assignment.left.expression, "globalThis") ||
          assignment.left.name.text !== "__yaaglD3MetalUpdate" || assignment.right.kind !== ts.SyntaxKind.TrueKeyword ||
          !isIdentifierNamed(call.expression, discovered.execIdent) || args.length !== 5 ||
          typeof stringLiteralValue(args[0]) !== "string" || !stringLiteralValue(args[0]).endsWith("/.zzz-wine-registration/zzz-wine-register") ||
          stringLiteralValue(args[1]) !== "--resource-path" || stringLiteralValue(args[3]) !== "--archive-path" ||
          typeof stringLiteralValue(args[4]) !== "string" || !ts.isCallExpression(args[2]) ||
          !isIdentifierNamed(args[2].expression, discovered.resolveIdent) || args[2].arguments.length !== 1 ||
          stringLiteralValue(args[2].arguments[0]) !== "./resources.neu.update") {
        throw new Error("Cannot recover a modified registration hook; current resources were preserved");
      }
      var catalog = findTargetDistribution(sourceFile, targetId);
      var changes = [{ start: wrapper.wrapperNode.getStart(sourceFile), end: wrapper.wrapperNode.end, replacement: text(wrapper.moveAwait, sourceFile) }];
      if (catalog.target) {
        var node = catalog.target.node;
        var array = catalogArray(catalog.distributions);
        if (node.parent !== array) throw new Error("Registered Wine is outside the catalog array");
        var index = array.elements.indexOf(node);
        var start = node.getStart(sourceFile);
        var end = node.end;
        if (index > 0) start = array.elements[index - 1].end;
        else if (array.elements.length > 1) end = array.elements[1].getStart(sourceFile);
        changes.push({ start: start, end: end, replacement: "" });
      }
      var output = applyChanges(source, changes);
      var outputFile = parse(output);
      if (output.includes("__yaaglD3MetalUpdate") || findTargetDistribution(outputFile, targetId).target) {
        throw new Error("Registration dependencies remain after recovery; current resources were preserved");
      }
      return { source: output, changed: true };
    } catch (error) {
      return { error: error && error.message ? error.message : String(error) };
    }
  };

  globalThis.__asarTransform = function (source, targetId, displayName, archiveURL, options) {
    try {
      if (typeof source !== "string" || typeof targetId !== "string" || typeof displayName !== "string" || typeof archiveURL !== "string") throw new Error("transform arguments must be strings");
      if (!options || typeof options !== "object" || typeof options.registrationHelperPath !== "string" || !options.registrationHelperPath || typeof options.archivePath !== "string" || !options.archivePath) {
        throw new Error("transform options must include registrationHelperPath and archivePath strings");
      }
      var protectedRuntimeIds = options.protectedRuntimeIds;
      if (!Array.isArray(protectedRuntimeIds) || !protectedRuntimeIds.length || protectedRuntimeIds.some(function (id) { return typeof id !== "string" || !id; })) {
        throw new Error("transform options must include a non-empty protectedRuntimeIds string array");
      }
      if (new Set(protectedRuntimeIds).size !== protectedRuntimeIds.length) throw new Error("protectedRuntimeIds must not contain duplicates");
      if (!protectedRuntimeIds.includes(targetId)) throw new Error("protectedRuntimeIds must include targetId");
      var sourceFile = parse(source);
      var record = JSON.stringify({
        id: targetId,
        displayName: displayName,
        remoteUrl: archiveURL,
        attributes: { id: targetId, renderBackend: "d3dmetal", winePath: "wine", supportsD3d12: true }
      });
      var catalog = findTargetDistribution(sourceFile, targetId);
      var changes = [];
      if (catalog.target) {
        changes = changes.concat(removePriorCatalogValidation(sourceFile, catalog.target.node));
        changes.push({ start: catalog.target.node.getStart(sourceFile), end: catalog.target.node.end, replacement: record });
      } else {
        var array = catalogArray(catalog.distributions);
        changes.push({ start: array.end - 1, end: array.end - 1, replacement: "," + record });
      }
      changes = changes.concat(localInstallerChanges(sourceFile, targetId, protectedRuntimeIds));
      changes = changes.concat(precomposedD3DMetalChanges(sourceFile));
      changes = changes.concat(launchChanges(sourceFile));
      changes = changes.concat(updaterChanges(sourceFile, options));
      var output = applyChanges(source, changes);
      var outputFile = parse(output);
      var outputCatalog = findTargetDistribution(outputFile, targetId);
      if (!outputCatalog.target) throw new Error("target Wine distribution was not present after transformation");
      if (outputCatalog.distributions.filter(function (distribution) { return distribution.id === targetId; }).length !== 1) throw new Error("target Wine distribution was duplicated after transformation");
      if (!output.includes("__yaaglD3MetalUpdate")) {
        throw new Error("updater registration hook was not present after transformation");
      }
      return { source: output, changed: output !== source };
    } catch (error) {
      return { error: error && error.message ? error.message : String(error) };
    }
  };
}());
