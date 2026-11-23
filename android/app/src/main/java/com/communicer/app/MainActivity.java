package com.communicer.app;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.provider.MediaStore;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.OutputStream;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Communicer : enveloppe Android de la version téléphone du site (phone/index.html).
 * Écran de démarrage, portrait + paysage, pleine page (barres système, encoche), écran maintenu allumé sur demande de la page,
 * caméra / micro / GPS / fichiers, Scommunicookie conservé dans l'application.
 */
public class MainActivity extends Activity {
    private static final int RQ_PERMS = 41, RQ_FILE = 42, RQ_WEB = 43, RQ_GEO = 44;
    private static final String PREFS = "communicer", KEYSTORE = "AndroidKeyStore", KEY_ALIAS = "cm_sc_key";

    private FrameLayout root;
    private WebView web;
    private View splash;
    private View customView;
    private WebChromeClient chrome;
    private WebChromeClient.CustomViewCallback customCb;
    private ValueCallback<Uri[]> fileCb;
    private PermissionRequest pendingWebPerm;
    private String pendingGeoOrigin;
    private GeolocationPermissions.Callback pendingGeoCb;
    private volatile boolean trusted = false;
    private boolean splashGone = false, failed = false, immersiveWanted = false;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private int padL, padT, padR, padB;

    @Override
    protected void onCreate(Bundle b) {
        setTheme(R.style.AppTheme);
        super.onCreate(b);
        Window w = getWindow();
        w.addFlags(WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED);
        if (Build.VERSION.SDK_INT >= 30) {
            w.setDecorFitsSystemWindows(false);
            WindowManager.LayoutParams lp = w.getAttributes();
            lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
            w.setAttributes(lp);
        } else {
            w.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
            if (Build.VERSION.SDK_INT >= 28) {
                WindowManager.LayoutParams lp = w.getAttributes();
                lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
                w.setAttributes(lp);
            }
        }
        w.setStatusBarColor(Color.TRANSPARENT);
        w.setNavigationBarColor(Color.TRANSPARENT);

        root = new FrameLayout(this);
        root.setBackgroundColor(getResources().getColor(R.color.brand));
        root.setOnApplyWindowInsetsListener((v, ins) -> {
            int l, t, r, bt;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets sys = ins.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                android.graphics.Insets ime = ins.getInsets(WindowInsets.Type.ime());
                l = sys.left; t = sys.top; r = sys.right; bt = Math.max(sys.bottom, ime.bottom);
            } else {
                l = ins.getSystemWindowInsetLeft(); t = ins.getSystemWindowInsetTop();
                r = ins.getSystemWindowInsetRight(); bt = ins.getSystemWindowInsetBottom();
            }
            padL = l; padT = t; padR = r; padB = bt;
            if (web != null) applyPadding();
            return ins;
        });
        setContentView(root);

        web = new WebView(this);
        web.setBackgroundColor(Color.TRANSPARENT);
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        applyPadding();
        buildSplash();
        setupWebView();
        requestAllPermissions();

        if (b != null) web.restoreState(b);
        else web.loadUrl(targetFor(getIntent()));
        // sécurité : l'écran de démarrage ne reste jamais plus de 12 s
        ui.postDelayed(this::hideSplash, 12000);
        applyOrientationBars(getResources().getConfiguration());
    }

    private void applyPadding() {
        web.setPadding(padL, padT, padR, padB);
        // le contenu est en padding : la zone derrière les barres prend la couleur du thème (voir Bridge.theme)
    }

    private void buildSplash() {
        LinearLayout s = new LinearLayout(this);
        s.setOrientation(LinearLayout.VERTICAL);
        s.setGravity(Gravity.CENTER);
        s.setBackgroundColor(getResources().getColor(R.color.brand));
        ImageView iv = new ImageView(this);
        iv.setImageResource(R.drawable.splash_logo);
        int sz = (int) (120 * getResources().getDisplayMetrics().density);
        s.addView(iv, new LinearLayout.LayoutParams(sz, sz));
        TextView tv = new TextView(this);
        tv.setText(R.string.app_name);
        tv.setTextColor(Color.WHITE);
        tv.setTextSize(26);
        tv.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        tv.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.topMargin = (int) (16 * getResources().getDisplayMetrics().density);
        s.addView(tv, lp);
        ProgressBar pb = new ProgressBar(this);
        LinearLayout.LayoutParams pl = new LinearLayout.LayoutParams((int) (36 * getResources().getDisplayMetrics().density), (int) (36 * getResources().getDisplayMetrics().density));
        pl.topMargin = (int) (22 * getResources().getDisplayMetrics().density);
        s.addView(pb, pl);
        splash = s;
        root.addView(s, new FrameLayout.LayoutParams(-1, -1));
    }

    private void hideSplash() {
        if (splashGone || splash == null) return;
        splashGone = true;
        splash.animate().alpha(0f).setDuration(300).withEndAction(() -> root.removeView(splash)).start();
    }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private void setupWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setGeolocationEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setAllowFileAccessFromFileURLs(false);
        s.setAllowUniversalAccessFromFileURLs(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setLoadWithOverviewMode(false);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(false);
        s.setSupportZoom(false);
        s.setUserAgentString(s.getUserAgentString() + " CommunicerApp/" + BuildConfig.APP_VERSION);
        CookieManager cm = CookieManager.getInstance();
        cm.setAcceptCookie(true);
        cm.setAcceptThirdPartyCookies(web, true);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.addJavascriptInterface(new Bridge(), "CMApp");

        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if (isOurs(u)) return false;
                if (u.getScheme() != null && u.getScheme().equals("file")) return true;
                openExternal(u);
                return true;
            }
            @Override public void onPageStarted(WebView v, String url, android.graphics.Bitmap f) {
                trusted = isOurs(Uri.parse(url));
                failed = false;
            }
            @Override public void onPageFinished(WebView v, String url) {
                trusted = isOurs(Uri.parse(url));
                if (failed) hideSplash(); // la page hors-ligne s'affiche
            }
            @Override public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame()) {
                    failed = true; trusted = false;
                    v.loadUrl("file:///android_asset/offline.html");
                    ui.postDelayed(MainActivity.this::hideSplash, 300);
                }
            }
        });

        chrome = new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest req) {
                runOnUiThread(() -> {
                    if (!isOurs(req.getOrigin())) { req.deny(); return; }
                    List<String> need = new ArrayList<>();
                    for (String r : req.getResources()) {
                        if (r.equals(PermissionRequest.RESOURCE_VIDEO_CAPTURE) && !has(Manifest.permission.CAMERA)) need.add(Manifest.permission.CAMERA);
                        if (r.equals(PermissionRequest.RESOURCE_AUDIO_CAPTURE) && !has(Manifest.permission.RECORD_AUDIO)) need.add(Manifest.permission.RECORD_AUDIO);
                    }
                    if (need.isEmpty()) req.grant(req.getResources());
                    else { pendingWebPerm = req; requestPermissions(need.toArray(new String[0]), RQ_WEB); }
                });
            }
            @Override public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback cb) {
                if (!isOurs(Uri.parse(origin))) { cb.invoke(origin, false, false); return; }
                if (has(Manifest.permission.ACCESS_FINE_LOCATION)) cb.invoke(origin, true, true);
                else { pendingGeoOrigin = origin; pendingGeoCb = cb; requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, RQ_GEO); }
            }
            @Override public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (fileCb != null) fileCb.onReceiveValue(null);
                fileCb = cb;
                try { startActivityForResult(p.createIntent(), RQ_FILE); }
                catch (ActivityNotFoundException e) { fileCb = null; return false; }
                return true;
            }
            @Override public void onShowCustomView(View view, CustomViewCallback cb) {
                if (customView != null) { cb.onCustomViewHidden(); return; }
                customView = view; customCb = cb;
                root.addView(view, new FrameLayout.LayoutParams(-1, -1));
                web.setVisibility(View.INVISIBLE);
                setImmersive(true);
            }
            @Override public void onHideCustomView() {
                if (customView == null) return;
                root.removeView(customView); customView = null;
                if (customCb != null) customCb.onCustomViewHidden();
                web.setVisibility(View.VISIBLE);
                setImmersive(immersiveWanted);
            }
        };
        web.setWebChromeClient(chrome);

        web.setDownloadListener(new DownloadListener() {
            @Override public void onDownloadStart(String url, String ua, String cd, String mime, long len) {
                String name = URLUtil.guessFileName(url, cd, mime);
                if (url.startsWith("blob:")) {
                    String js = "(async()=>{try{const r=await fetch('" + url + "');const b=await r.blob();const f=new FileReader();"
                            + "f.onloadend=()=>CMApp.saveBase64(" + quote(name) + "," + quote(mime == null ? "application/octet-stream" : mime) + ",String(f.result).split(',')[1]);f.readAsDataURL(b)}catch(e){}})()";
                    web.evaluateJavascript(js, null);
                } else if (url.startsWith("data:")) {
                    try { int i = url.indexOf(','); saveFile(name, mime, Base64.decode(url.substring(i + 1), Base64.DEFAULT)); } catch (Exception e) { toast("Téléchargement impossible"); }
                } else {
                    try {
                        DownloadManager.Request rq = new DownloadManager.Request(Uri.parse(url));
                        rq.setMimeType(mime);
                        rq.addRequestHeader("User-Agent", ua);
                        rq.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                        rq.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
                        ((DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(rq);
                        toast("Téléchargement : " + name);
                    } catch (Exception e) { openExternal(Uri.parse(url)); }
                }
            }
        });
    }

    private static String quote(String s) { return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"; }

    private void saveFile(String name, String mime, byte[] data) throws Exception {
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues cv = new ContentValues();
            cv.put(MediaStore.Downloads.DISPLAY_NAME, name);
            if (mime != null) cv.put(MediaStore.Downloads.MIME_TYPE, mime);
            cv.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
            Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
            try (OutputStream o = getContentResolver().openOutputStream(u)) { o.write(data); }
        } else {
            java.io.File f = new java.io.File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), name);
            try (java.io.FileOutputStream o = new java.io.FileOutputStream(f)) { o.write(data); }
        }
        toast("Enregistré dans Téléchargements : " + name);
    }

    private boolean has(String p) { return checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED; }

    /** Le site doit disposer de tous les droits : demandés une fois au premier lancement (puis à chaque besoin). */
    private void requestAllPermissions() {
        SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (sp.getBoolean("asked", false)) return;
        sp.edit().putBoolean("asked", true).apply();
        List<String> l = new ArrayList<>();
        l.add(Manifest.permission.CAMERA);
        l.add(Manifest.permission.RECORD_AUDIO);
        l.add(Manifest.permission.ACCESS_FINE_LOCATION);
        l.add(Manifest.permission.ACCESS_COARSE_LOCATION);
        if (Build.VERSION.SDK_INT >= 33) {
            l.add(Manifest.permission.READ_MEDIA_IMAGES); l.add(Manifest.permission.READ_MEDIA_VIDEO);
            l.add(Manifest.permission.READ_MEDIA_AUDIO); l.add(Manifest.permission.POST_NOTIFICATIONS);
        } else if (Build.VERSION.SDK_INT >= 23) {
            l.add(Manifest.permission.READ_EXTERNAL_STORAGE);
            if (Build.VERSION.SDK_INT <= 28) l.add(Manifest.permission.WRITE_EXTERNAL_STORAGE);
        }
        requestPermissions(l.toArray(new String[0]), RQ_PERMS);
    }

    @Override public void onRequestPermissionsResult(int rc, String[] perms, int[] res) {
        boolean ok = res.length > 0;
        for (int r : res) if (r != PackageManager.PERMISSION_GRANTED) ok = false;
        if (rc == RQ_WEB && pendingWebPerm != null) {
            if (ok) pendingWebPerm.grant(pendingWebPerm.getResources()); else pendingWebPerm.deny();
            pendingWebPerm = null;
        } else if (rc == RQ_GEO && pendingGeoCb != null) {
            pendingGeoCb.invoke(pendingGeoOrigin, ok || has(Manifest.permission.ACCESS_COARSE_LOCATION), true);
            pendingGeoCb = null;
        }
    }

    @Override protected void onActivityResult(int rq, int rs, Intent d) {
        if (rq == RQ_FILE && fileCb != null) {
            fileCb.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(rs, d));
            fileCb = null;
        } else super.onActivityResult(rq, rs, d);
    }

    // ---- adresse : le site est « de confiance » seulement sur son propre domaine
    private boolean isOurs(Uri u) {
        if (u == null || u.getHost() == null) return false;
        Uri base = Uri.parse(BuildConfig.APP_URL);
        return "https".equals(u.getScheme()) && u.getHost().equalsIgnoreCase(base.getHost());
    }

    private void openExternal(Uri u) {
        try { startActivity(new Intent(Intent.ACTION_VIEW, u).addCategory(Intent.CATEGORY_BROWSABLE)); }
        catch (Exception e) { toast("Aucune application pour ouvrir ce lien"); }
    }

    /** Lien reçu (https://rromanou.github.io/Communicer/...) -> version téléphone avec les mêmes paramètres que 404.html. */
    private String targetFor(Intent in) {
        String home = BuildConfig.APP_URL;
        Uri d = in == null ? null : in.getData();
        if (d == null || !isOurs(d)) return home;
        String base = Uri.parse(home).getPath().replaceAll("phone/?$", "");
        String p = d.getPath() == null ? "" : d.getPath();
        if (p.startsWith(base)) p = p.substring(base.length());
        if (p.startsWith("/")) p = p.substring(1);
        p = p.replaceAll("/$", "");
        String q = d.getEncodedQuery() == null ? "" : d.getEncodedQuery();
        if (p.startsWith("phone")) return d.toString();
        if (p.startsWith("@")) return home + "?u=" + Uri.encode(p.substring(1).toLowerCase());
        if (p.startsWith("c@")) return home + "?go=cu&id=" + Uri.encode(p.substring(2).toLowerCase());
        if (p.matches("group|user|bots|friend-request|ref|event")) return home + "?go=" + p + (q.isEmpty() ? "" : "&" + q);
        if (!q.isEmpty() && (q.startsWith("go=") || q.startsWith("u="))) return home + "?" + q;
        return home;
    }

    @Override protected void onNewIntent(Intent in) {
        super.onNewIntent(in);
        setIntent(in);
        if (in != null && in.getData() != null) web.loadUrl(targetFor(in));
    }

    // ---- barres système / orientation
    private void setImmersive(boolean on) {
        View dv = getWindow().getDecorView();
        if (Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                if (on) { c.hide(WindowInsets.Type.systemBars()); c.setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE); }
                else c.show(WindowInsets.Type.systemBars());
            }
        } else {
            int f = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
            if (on) f |= View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY;
            dv.setSystemUiVisibility(f);
        }
    }

    private void applyOrientationBars(Configuration c) {
        // paysage : barres masquées (balayer le bord pour les revoir) ; portrait : barres visibles
        immersiveWanted = c.orientation == Configuration.ORIENTATION_LANDSCAPE;
        if (customView == null) setImmersive(immersiveWanted);
    }

    @Override public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        applyOrientationBars(c);
        root.requestApplyInsets();
    }

    @Override public void onWindowFocusChanged(boolean f) {
        super.onWindowFocusChanged(f);
        if (f && (customView != null || immersiveWanted)) setImmersive(true);
    }

    @Override public void onBackPressed() {
        if (customView != null) { chrome.onHideCustomView(); return; }
        if (web.canGoBack() && !failed) web.goBack(); else moveTaskToBack(true);
    }

    @Override protected void onSaveInstanceState(Bundle b) { super.onSaveInstanceState(b); web.saveState(b); }
    @Override protected void onResume() { super.onResume(); web.onResume(); }
    @Override protected void onDestroy() { try { web.destroy(); } catch (Exception e) { } super.onDestroy(); }

    private void toast(String m) { runOnUiThread(() -> Toast.makeText(this, m, Toast.LENGTH_SHORT).show()); }

    // ---- Scommunicookie : conservé dans l'application, chiffré avec une clé du Keystore Android
    private String scLoad() {
        try {
            String v = getSharedPreferences(PREFS, MODE_PRIVATE).getString("sc", null);
            if (v == null) return "";
            byte[] all = Base64.decode(v, Base64.NO_WRAP);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, scKey(), new GCMParameterSpec(128, all, 0, 12));
            return new String(c.doFinal(all, 12, all.length - 12), "UTF-8");
        } catch (Exception e) { return ""; }
    }

    private void scSave(String val) {
        try {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, scKey());
            byte[] iv = c.getIV(), ct = c.doFinal(val.getBytes("UTF-8")), all = new byte[iv.length + ct.length];
            System.arraycopy(iv, 0, all, 0, iv.length);
            System.arraycopy(ct, 0, all, iv.length, ct.length);
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString("sc", Base64.encodeToString(all, Base64.NO_WRAP)).apply();
        } catch (Exception e) { }
    }

    private SecretKey scKey() throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE);
        ks.load(null);
        if (!ks.containsAlias(KEY_ALIAS)) {
            KeyGenerator g = KeyGenerator.getInstance("AES", KEYSTORE);
            g.init(new android.security.keystore.KeyGenParameterSpec.Builder(KEY_ALIAS,
                    android.security.keystore.KeyProperties.PURPOSE_ENCRYPT | android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).build());
            return g.generateKey();
        }
        return ((KeyStore.SecretKeyEntry) ks.getEntry(KEY_ALIAS, null)).getSecretKey();
    }

    /** Pont JavaScript : n'obéit qu'à la page du site (domaine vérifié). */
    private class Bridge {
        @JavascriptInterface public String scGet() { return trusted ? scLoad() : ""; }
        @JavascriptInterface public void scSet(String v) { if (trusted && v != null && v.matches("^SC1\\.[0-9a-f]{48}\\.[0-9a-f]{64}$")) scSave(v); }
        @JavascriptInterface public void keepAwake(boolean on) {
            if (!trusted) return;
            runOnUiThread(() -> { if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); });
        }
        @JavascriptInterface public void splashDone() { if (trusted) runOnUiThread(MainActivity.this::hideSplash); }
        @JavascriptInterface public void fullscreen(boolean on) { /* la vidéo plein écran passe par onShowCustomView */ }
        @JavascriptInterface public void theme(String color) {
            if (!trusted) return;
            try { final int c = Color.parseColor(color); runOnUiThread(() -> root.setBackgroundColor(c)); } catch (Exception e) { }
        }
        @JavascriptInterface public void vibrate(int ms) {
            if (!trusted) return;
            Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null) return;
            int d = Math.max(1, Math.min(ms, 500));
            if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createOneShot(d, VibrationEffect.DEFAULT_AMPLITUDE)); else v.vibrate(d);
        }
        @JavascriptInterface public String version() { return BuildConfig.APP_VERSION; }
        @JavascriptInterface public void saveBase64(String name, String mime, String b64) {
            if (!trusted) return;
            try { saveFile(name, mime, Base64.decode(b64, Base64.DEFAULT)); } catch (Exception e) { toast("Enregistrement impossible"); }
        }
        @JavascriptInterface public void reload() {
            runOnUiThread(() -> {
                failed = false; web.loadUrl(BuildConfig.APP_URL);
            });
        }
    }
}
