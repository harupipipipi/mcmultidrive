/**
 * MC MultiDrive — Google Apps Script (複数ワールド対応)
 *
 * スプレッドシートに "status" シートを作成し、このスクリプトを
 * ウェブアプリとしてデプロイしてください。
 *
 * status シート構成:
 *   A列: world_name
 *   B列: status (online / offline)
 *   C列: host
 *   D列: domain
 *   E列: lock_timestamp (UTC ISO8601)
 */

function getSheet() {
  return SpreadsheetApp.getActiveSpreadsheet().getSheetByName("status");
}

function findRow(sheet, worldName) {
  var data = sheet.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (data[i][0] === worldName) {
      return i + 1; // 1-indexed
    }
  }
  return -1;
}

function jsonResponse(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ─── GET ─────────────────────────────────────────

function doGet(e) {
  var action = (e.parameter.action || "list_worlds");
  var sheet = getSheet();

  if (action === "list_worlds") {
    return listWorlds(sheet);
  }
  if (action === "get_status") {
    return getStatus(sheet, e.parameter.world || "");
  }

  return jsonResponse({error: "unknown action"});
}

function listWorlds(sheet) {
  var data = sheet.getDataRange().getValues();
  var worlds = [];
  for (var i = 0; i < data.length; i++) {
    if (!data[i][0]) continue;
    worlds.push({
      world_name:     data[i][0],
      status:         data[i][1] || "offline",
      host:           data[i][2] || "",
      domain:         data[i][3] || "",
      lock_timestamp: data[i][4] || "",
    });
  }
  return jsonResponse({worlds: worlds});
}

function getStatus(sheet, worldName) {
  var row = findRow(sheet, worldName);
  if (row === -1) {
    return jsonResponse({status: "not_found"});
  }
  var vals = sheet.getRange(row, 1, 1, 5).getValues()[0];
  return jsonResponse({
    world_name:     vals[0],
    status:         vals[1] || "offline",
    host:           vals[2] || "",
    domain:         vals[3] || "",
    lock_timestamp: vals[4] || "",
  });
}

// ─── POST ────────────────────────────────────────

function doPost(e) {
  var data = JSON.parse(e.postData.contents);
  var sheet = getSheet();
  var action = data.action || "";

  switch (action) {
    case "set_online":
      return setOnline(sheet, data);
    case "set_offline":
      return setOffline(sheet, data);
    case "update_domain":
      return updateDomain(sheet, data);
    case "add_world":
      return addWorld(sheet, data);
    case "delete_world":
      return deleteWorld(sheet, data);
    default:
      return jsonResponse({success: false, error: "unknown action"});
  }
}

function setOnline(sheet, data) {
  var world = data.world || "";
  var host  = data.host  || "";
  var domain = data.domain || "preparing...";

  if (!world || !host) {
    return jsonResponse({success: false, error: "missing world or host"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  var currentStatus = sheet.getRange(row, 2).getValue();
  var currentHost   = sheet.getRange(row, 3).getValue();

  if (currentStatus === "online" && currentHost && currentHost !== host) {
    return jsonResponse({
      success: false,
      current_host: currentHost,
      error: "already hosted by " + currentHost,
    });
  }

  var now = new Date().toISOString();
  sheet.getRange(row, 2).setValue("online");
  sheet.getRange(row, 3).setValue(host);
  sheet.getRange(row, 4).setValue(domain);
  sheet.getRange(row, 5).setValue(now);

  return jsonResponse({success: true, current_host: host});
}

function setOffline(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  sheet.getRange(row, 2).setValue("offline");
  sheet.getRange(row, 3).setValue("");
  sheet.getRange(row, 4).setValue("");
  sheet.getRange(row, 5).setValue("");

  return jsonResponse({success: true});
}

function updateDomain(sheet, data) {
  var world  = data.world  || "";
  var domain = data.domain || "";

  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  sheet.getRange(row, 4).setValue(domain);
  return jsonResponse({success: true});
}

function addWorld(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row !== -1) {
    return jsonResponse({success: true, message: "already exists"});
  }

  var lastRow = sheet.getLastRow();
  sheet.getRange(lastRow + 1, 1).setValue(world);
  sheet.getRange(lastRow + 1, 2).setValue("offline");

  return jsonResponse({success: true});
}


function deleteWorld(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  // ステータスがオンラインなら削除不可
  var status = sheet.getRange(row, 2).getValue();
  if (status === "online") {
    return jsonResponse({success: false, error: "cannot delete online world"});
  }

  sheet.deleteRow(row);
  return jsonResponse({success: true});
}
