# Result sheet mailing: one-time setup

When you close (deactivate) an examination, the portal emails each paper's examiner one Excel sheet and one Word sheet listing every registered student with their score (absentees are marked Absent). Mail is sent from your own Gmail through a small Google Apps Script.

## 1. Create the mailer script

1. Go to <https://script.google.com> signed in as the Gmail account that should send the mail, and choose **New project**.
2. Replace the contents with `docs/result-mailer.gs` from this repo.
3. **Project Settings (gear) → Script properties → Add script property**
   - Property: `MAIL_TOKEN`
   - Value: a long random string (keep it, you need it in step 3).
4. **Deploy → New deployment → Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
   - Click **Deploy**, approve the permission prompts, and copy the **Web app URL**.

Gmail allows about 100 recipients a day for a personal account (about 1,500 with Google Workspace). At 20 papers a day this is well inside the limit.

## 2. Give the portal the URL and token

```powershell
supabase secrets set GAS_MAIL_URL="<the web app URL>" GAS_MAIL_TOKEN="<the MAIL_TOKEN value>"
supabase functions deploy send-result-sheets
supabase functions deploy upload-student-photo
```

## 3. Test it

SuperAdmin → Settings → Result sheet mailing → **Send a test email**. You should receive a sample sheet with both attachments within a minute.

## How it works

- Each paper has an **Examiner email** (SuperAdmin → Examinations → Edit). Up to three addresses, separated by commas.
- Closing an exam queues one sheet per paper that has an examiner email. Settings → Result sheet mailing shows the queue, and **Send pending now** delivers anything waiting. Failed deliveries show the reason and can be retried.
- If you change the Apps Script code later, create a **new version** of the deployment (Deploy → Manage deployments → Edit → New version) so the web app URL keeps working.
