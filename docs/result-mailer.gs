/**
 * Result sheet mailer for the College CBT portal.
 *
 * The portal's send-result-sheets function posts a JSON message here and this
 * script sends it from your Gmail account with the Excel and Word attachments.
 *
 * Setup: see docs/result-mailing-setup.md
 */
function doPost(e) {
  try {
    var expected = PropertiesService.getScriptProperties().getProperty('MAIL_TOKEN');
    var body = JSON.parse(e.postData.contents);

    if (!expected || body.token !== expected) {
      return reply_({ ok: false, error: 'Unauthorized' });
    }
    if (!body.to || !body.subject) {
      return reply_({ ok: false, error: 'Missing recipient or subject' });
    }

    var attachments = (body.attachments || []).map(function (a) {
      return Utilities.newBlob(Utilities.base64Decode(a.base64), a.mimeType, a.filename);
    });

    MailApp.sendEmail({
      to: body.to,
      subject: body.subject,
      htmlBody: body.htmlBody || '',
      attachments: attachments,
      name: 'College CBT Results'
    });

    return reply_({ ok: true });
  } catch (err) {
    return reply_({ ok: false, error: String(err) });
  }
}

function reply_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
