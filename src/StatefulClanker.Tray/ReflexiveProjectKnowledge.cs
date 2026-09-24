using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StatefulClanker.Tray;

static class ReflexiveProjectKnowledge
{
    const string SchemaVersion = "3";
    static readonly JsonSerializerOptions Json = new() { WriteIndented = false };
    static readonly HashSet<string> IgnoredDirs = new(StringComparer.OrdinalIgnoreCase)
        { ".git", ".statefulclanker", "bin", "obj", ".vs", "node_modules", "packages", "install\\output", "install\\publish" };
    static readonly HashSet<string> TextExt = new(StringComparer.OrdinalIgnoreCase)
        { ".cs",".ps1",".psm1",".psd1",".py",".js",".ts",".tsx",".jsx",".json",".md",".yml",".yaml",".toml",".xml",".csproj",".sln",".sql",".html",".css",".txt" };

    public static int Run(string[] args)
    {
        try
        {
            var a = Parse(args);
            var cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
            var project = Path.GetFullPath(Get(a, "project", Environment.CurrentDirectory));
            return cmd switch
            {
                "init" => Init(project),
                "index" => Index(project),
                "query" => Query(project, Get(a,"text",""), Get(a,"paths",""), Int(a,"limit",8)),
                "lesson-add" => AddLesson(project, Get(a,"title",""), Get(a,"body",""), Get(a,"tags",""), Get(a,"paths",""), Get(a,"source","worker"), Double(a,"confidence",0.75)),
                "lesson-confirm" => ConfirmLesson(project, Get(a,"id",""), Get(a,"note","")),
                "lesson-reject" => RejectLesson(project, Get(a,"id",""), Get(a,"note","")),
                "normalize" => Normalize(project),
                "neighbors" => Neighbors(project, Get(a,"path",""), Int(a,"depth",1), Int(a,"limit",50)),
                "status" => Status(project),
                _ => Emit(new { ok=false, error="rpk commands: init, index, query, lesson-add, lesson-confirm, lesson-reject, normalize, neighbors, status" }, 2)
            };
        }
        catch(Exception ex) { return Emit(new { ok=false, error=ex.Message }, 1); }
    }

    static Dictionary<string,string> Parse(string[] args)
    {
        var d=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        for(int i=1;i<args.Length;i++) if(args[i].StartsWith("--"))
        { var k=args[i][2..]; d[k]=(i+1<args.Length&&!args[i+1].StartsWith("--"))?args[++i]:"true"; }
        return d;
    }
    static string Get(Dictionary<string,string> a,string k,string d="")=>a.TryGetValue(k,out var v)?v:d;
    static int Int(Dictionary<string,string>a,string k,int d)=>int.TryParse(Get(a,k),out var v)?v:d;
    static double Double(Dictionary<string,string>a,string k,double d)=>double.TryParse(Get(a,k),out var v)?v:d;
    static int Emit(object value,int code=0)
    {
        var bytes=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value,Json)+Environment.NewLine);
        using var s=Console.OpenStandardOutput(); s.Write(bytes,0,bytes.Length); s.Flush(); return code;
    }
    static string DbPath(string project)
    {
        var dir=Path.Combine(project,".clanker"); Directory.CreateDirectory(dir); return Path.Combine(dir,"reflexive-project-knowledge.sqlite");
    }
    static SqliteConnection Open(string project)
    {
        var c=new SqliteConnection($"Data Source={DbPath(project)};Mode=ReadWriteCreate;Cache=Shared"); c.Open();
        using var pragma=c.CreateCommand(); pragma.CommandText="PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"; pragma.ExecuteNonQuery();
        Ensure(c); MigrateSchema(c); return c;
    }
    static void Ensure(SqliteConnection c)
    {
        using var q=c.CreateCommand(); q.CommandText=@"
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,sha256 TEXT NOT NULL,size INTEGER NOT NULL,mtime_utc TEXT NOT NULL,language TEXT,updated_utc TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS symbols(id TEXT PRIMARY KEY,path TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,line INTEGER NOT NULL,signature TEXT);
CREATE INDEX IF NOT EXISTS ix_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS ix_symbols_path ON symbols(path);
CREATE TABLE IF NOT EXISTS edges(src TEXT NOT NULL,dst TEXT NOT NULL,kind TEXT NOT NULL,weight REAL NOT NULL DEFAULT 1,provenance TEXT,dst_resolved TEXT,updated_utc TEXT NOT NULL,PRIMARY KEY(src,dst,kind));
CREATE INDEX IF NOT EXISTS ix_edges_dst ON edges(dst);
CREATE TABLE IF NOT EXISTS lessons(id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'active',confidence REAL NOT NULL DEFAULT .75,source TEXT,created_utc TEXT NOT NULL,updated_utc TEXT NOT NULL,last_confirmed_utc TEXT,normalization_note TEXT);
CREATE TABLE IF NOT EXISTS lesson_tags(lesson_id TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(lesson_id,tag),FOREIGN KEY(lesson_id) REFERENCES lessons(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS ix_lesson_tags_tag ON lesson_tags(tag);
CREATE TABLE IF NOT EXISTS lesson_paths(lesson_id TEXT NOT NULL,path TEXT NOT NULL,file_sha TEXT,PRIMARY KEY(lesson_id,path),FOREIGN KEY(lesson_id) REFERENCES lessons(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS ix_lesson_paths_path ON lesson_paths(path);
"; q.ExecuteNonQuery();
    }

    // Migrates older RPK databases in place: converts autoincrement symbol ids to stable
    // content-derived ids and adds edge resolution columns. Never touches lesson* tables.
    static void MigrateSchema(SqliteConnection c)
    {
        string version="1";
        using(var g=c.CreateCommand()){g.CommandText="SELECT value FROM meta WHERE key='schema_version'";var v=g.ExecuteScalar() as string; if(v!=null)version=v;}
        if(version==SchemaVersion) return;
        using var tx=c.BeginTransaction();
        bool symbolsNeedMigration=false;
        using(var pi=c.CreateCommand()){pi.Transaction=tx;pi.CommandText="PRAGMA table_info(symbols)";using var r=pi.ExecuteReader();while(r.Read()){if(string.Equals(r.GetString(1),"id",StringComparison.OrdinalIgnoreCase)&&r.GetString(2).Contains("INT",StringComparison.OrdinalIgnoreCase))symbolsNeedMigration=true;}}
        if(symbolsNeedMigration)
        {
            using(var create=c.CreateCommand()){create.Transaction=tx;create.CommandText="CREATE TABLE symbols_v3(id TEXT PRIMARY KEY,path TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,line INTEGER NOT NULL,signature TEXT)";create.ExecuteNonQuery();}
            var rows=new List<(string path,string name,string kind,int line,string? sig)>();
            using(var sel=c.CreateCommand()){sel.Transaction=tx;sel.CommandText="SELECT path,name,kind,line,signature FROM symbols";using var r=sel.ExecuteReader();while(r.Read())rows.Add((r.GetString(0),r.GetString(1),r.GetString(2),r.GetInt32(3),r.IsDBNull(4)?null:r.GetString(4)));}
            foreach(var row in rows)
            {
                var id=SymbolId(row.path,row.kind,row.name);
                using var ins=c.CreateCommand();ins.Transaction=tx;ins.CommandText="INSERT OR REPLACE INTO symbols_v3(id,path,name,kind,line,signature) VALUES($i,$p,$n,$k,$l,$s)";
                ins.Parameters.AddWithValue("$i",id);ins.Parameters.AddWithValue("$p",row.path);ins.Parameters.AddWithValue("$n",row.name);ins.Parameters.AddWithValue("$k",row.kind);ins.Parameters.AddWithValue("$l",row.line);ins.Parameters.AddWithValue("$s",(object?)row.sig??DBNull.Value);ins.ExecuteNonQuery();
            }
            using(var drop=c.CreateCommand()){drop.Transaction=tx;drop.CommandText="DROP TABLE symbols; ALTER TABLE symbols_v3 RENAME TO symbols; CREATE INDEX IF NOT EXISTS ix_symbols_name ON symbols(name); CREATE INDEX IF NOT EXISTS ix_symbols_path ON symbols(path);";drop.ExecuteNonQuery();}
        }
        bool hasResolved=false;
        using(var pi=c.CreateCommand()){pi.Transaction=tx;pi.CommandText="PRAGMA table_info(edges)";using var r=pi.ExecuteReader();while(r.Read()){if(string.Equals(r.GetString(1),"dst_resolved",StringComparison.OrdinalIgnoreCase))hasResolved=true;}}
        if(!hasResolved){using var alter=c.CreateCommand();alter.Transaction=tx;alter.CommandText="ALTER TABLE edges ADD COLUMN dst_resolved TEXT";alter.ExecuteNonQuery();}
        using(var set=c.CreateCommand()){set.Transaction=tx;set.CommandText="INSERT INTO meta(key,value) VALUES('schema_version',$v) ON CONFLICT(key) DO UPDATE SET value=excluded.value";set.Parameters.AddWithValue("$v",SchemaVersion);set.ExecuteNonQuery();}
        tx.Commit();
    }

    static int Init(string project){using var c=Open(project);return Emit(new{ok=true,project,db=DbPath(project)});}
    static string Rel(string root,string full)=>Path.GetRelativePath(root,full).Replace('\\','/');
    static bool Ignored(string root,string full)
    {
        var rel=Rel(root,full); return rel.Split('/').Any(p=>IgnoredDirs.Contains(p)) || rel.StartsWith(".clanker/",StringComparison.OrdinalIgnoreCase);
    }
    static string Sha(string path){using var s=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant();}
    static string Lang(string path)=>Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    // Stable symbol id derived from (relative path, kind, qualified name). Independent of
    // line number so a symbol keeps its identity — and any lessons/anchors pointed at it —
    // across pure line-shift edits.
    static string SymbolId(string path,string kind,string name)
    {
        var bytes=SHA256.HashData(Encoding.UTF8.GetBytes(path+"#"+kind+":"+name));
        return Convert.ToHexString(bytes)[..16].ToLowerInvariant();
    }

    static IEnumerable<(string name,string kind,int line,string sig)> ExtractSymbols(string path)
    {
        var ext=Path.GetExtension(path).ToLowerInvariant(); string[] lines; try{lines=File.ReadAllLines(path);}catch{yield break;}
        Regex rx=ext switch {
            ".cs"=>new(@"\b(class|record|interface|struct|enum|void|public|private|internal|protected)\s+(?:static\s+|async\s+)?(?:[\w<>,?\[\]]+\s+)?([A-Za-z_]\w*)\s*(?:\(|[:{])"),
            ".ps1" or ".psm1"=>new(@"^\s*function\s+([A-Za-z0-9_-]+)",RegexOptions.IgnoreCase),
            ".py"=>new(@"^\s*(class|def)\s+([A-Za-z_]\w*)"),
            ".js" or ".ts" or ".tsx" or ".jsx"=>new(@"\b(class|function)\s+([A-Za-z_$][\w$]*)|\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\("),
            _=>new(@"$a")
        };
        for(int i=0;i<lines.Length;i++){var m=rx.Match(lines[i]);if(!m.Success)continue;var name=m.Groups.Cast<Group>().Skip(1).LastOrDefault(g=>g.Success)?.Value??"";if(string.IsNullOrWhiteSpace(name))continue;var kind=lines[i].Contains("class ")?"class":lines[i].Contains("function ",StringComparison.OrdinalIgnoreCase)?"function":"symbol";yield return(name,kind,i+1,lines[i].Trim());}
    }
    static IEnumerable<string> ExtractRefs(string path)
    {
        string text;try{text=File.ReadAllText(path);}catch{yield break;}
        foreach(Match m in Regex.Matches(text,@"(?im)^\s*(?:using|import|from|require\s*\(|\.\s*)\s*['""]?([A-Za-z0-9_./\\-]+)")) if(m.Groups[1].Success)yield return m.Groups[1].Value;
    }

    // Typed, kind-classified edges: 'imports' for using/Import-Module statements, and
    // 'dot-sources' for PowerShell dot-sourcing. Falls back to the legacy generic
    // 'references' scan for everything (kept for back-compat with older callers/tests).
    static IEnumerable<(string raw,string kind)> ExtractEdges(string path)
    {
        var ext=Path.GetExtension(path).ToLowerInvariant();
        string text; try{text=File.ReadAllText(path);}catch{yield break;}
        if(ext==".ps1"||ext==".psm1")
        {
            foreach(Match m in Regex.Matches(text,@"(?im)^\s*\.\s+['""]?([^'""\r\n]+\.ps(?:1|m1))['""]?\s*$"))
                if(m.Groups[1].Success) yield return (m.Groups[1].Value.Trim(),"dot-sources");
            foreach(Match m in Regex.Matches(text,@"(?im)Import-Module\s+['""]?([^\s'""]+)"))
                if(m.Groups[1].Success) yield return (m.Groups[1].Value.Trim(),"imports");
        }
        else if(ext==".cs")
        {
            foreach(Match m in Regex.Matches(text,@"(?m)^\s*using\s+([A-Za-z0-9_.]+)\s*;"))
                if(m.Groups[1].Success) yield return (m.Groups[1].Value,"imports");
        }
        foreach(var r in ExtractRefs(path)) yield return (r,"references");
    }

    // Resolves a raw import/dot-source target to an indexed project-relative file path,
    // trying the source file's own directory first, then the project root.
    static string? ResolveTarget(string projectRoot,string sourceRelPath,string raw)
    {
        var cleaned=raw.Replace("$PSScriptRoot",".",StringComparison.OrdinalIgnoreCase).Trim().Trim('\'','"');
        if(cleaned.Length==0) return null;
        var srcDir=Path.GetDirectoryName(Path.Combine(projectRoot,sourceRelPath))??projectRoot;
        var candidates=new List<string>();
        try{candidates.Add(Path.GetFullPath(Path.Combine(srcDir,cleaned)));}catch{}
        try{candidates.Add(Path.GetFullPath(Path.Combine(projectRoot,cleaned.TrimStart('.','/','\\'))));}catch{}
        foreach(var cand in candidates)
        {
            if(File.Exists(cand))
            {
                var rel=Rel(projectRoot,cand);
                if(!Ignored(projectRoot,cand)) return rel;
            }
        }
        return null;
    }

    static int Index(string project)
    {
        using var c=Open(project); using var tx=c.BeginTransaction();
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int changed=0,symbolCount=0,edgeCount=0,unchangedSkipped=0;
        var known=new Dictionary<string,(long size,string mtime,string sha)>(StringComparer.OrdinalIgnoreCase);
        using(var q=c.CreateCommand()){q.Transaction=tx;q.CommandText="SELECT path,size,mtime_utc,sha256 FROM files";using var r=q.ExecuteReader();while(r.Read())known[r.GetString(0)]=(r.GetInt64(1),r.GetString(2),r.GetString(3));}

        foreach(var full in Directory.EnumerateFiles(project,"*",SearchOption.AllDirectories))
        {
            if(Ignored(project,full)||!TextExt.Contains(Path.GetExtension(full)))continue;
            var fi=new FileInfo(full);if(fi.Length>2_000_000)continue;
            var rel=Rel(project,full); seen.Add(rel);
            var mtime=fi.LastWriteTimeUtc.ToString("O");

            if(known.TryGetValue(rel,out var prev) && prev.size==fi.Length && prev.mtime==mtime)
            {
                // Size+mtime match the stored row: skip re-reading/hashing entirely.
                unchangedSkipped++; continue;
            }

            var sha=Sha(full);
            if(known.TryGetValue(rel,out var prev2) && prev2.sha==sha)
            {
                // Content is unchanged (mtime bumped without a real edit): refresh metadata only.
                using var up0=c.CreateCommand();up0.Transaction=tx;up0.CommandText="UPDATE files SET size=$s,mtime_utc=$m,updated_utc=$u WHERE path=$p";
                up0.Parameters.AddWithValue("$s",fi.Length);up0.Parameters.AddWithValue("$m",mtime);up0.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));up0.Parameters.AddWithValue("$p",rel);up0.ExecuteNonQuery();
                continue;
            }

            changed++;
            using(var up=c.CreateCommand()){up.Transaction=tx;up.CommandText="INSERT INTO files(path,sha256,size,mtime_utc,language,updated_utc) VALUES($p,$h,$s,$m,$l,$u) ON CONFLICT(path) DO UPDATE SET sha256=excluded.sha256,size=excluded.size,mtime_utc=excluded.mtime_utc,language=excluded.language,updated_utc=excluded.updated_utc";up.Parameters.AddWithValue("$p",rel);up.Parameters.AddWithValue("$h",sha);up.Parameters.AddWithValue("$s",fi.Length);up.Parameters.AddWithValue("$m",mtime);up.Parameters.AddWithValue("$l",Lang(full));up.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));up.ExecuteNonQuery();}
            using(var del=c.CreateCommand()){del.Transaction=tx;del.CommandText="DELETE FROM symbols WHERE path=$p; DELETE FROM edges WHERE src=$p;";del.Parameters.AddWithValue("$p",rel);del.ExecuteNonQuery();}

            var now=DateTimeOffset.UtcNow.ToString("O");
            foreach(var s in ExtractSymbols(full))
            {
                var id=SymbolId(rel,s.kind,s.name);
                using(var ins=c.CreateCommand()){ins.Transaction=tx;ins.CommandText="INSERT OR REPLACE INTO symbols(id,path,name,kind,line,signature) VALUES($i,$p,$n,$k,$l,$s)";ins.Parameters.AddWithValue("$i",id);ins.Parameters.AddWithValue("$p",rel);ins.Parameters.AddWithValue("$n",s.name);ins.Parameters.AddWithValue("$k",s.kind);ins.Parameters.AddWithValue("$l",s.line);ins.Parameters.AddWithValue("$s",s.sig);ins.ExecuteNonQuery();symbolCount++;}
                using(var e=c.CreateCommand()){e.Transaction=tx;e.CommandText="INSERT INTO edges(src,dst,kind,weight,provenance,dst_resolved,updated_utc) VALUES($s,$d,'defines',1,'static-scan:resolved',$d,$u) ON CONFLICT(src,dst,kind) DO UPDATE SET updated_utc=excluded.updated_utc,dst_resolved=excluded.dst_resolved";e.Parameters.AddWithValue("$s",rel);e.Parameters.AddWithValue("$d",id);e.Parameters.AddWithValue("$u",now);edgeCount+=e.ExecuteNonQuery();}
            }
            foreach(var (raw,kind) in ExtractEdges(full).Distinct())
            {
                var target=raw.Replace('\\','/');
                var resolved=(kind=="imports"||kind=="dot-sources")?ResolveTarget(project,rel,target):null;
                var provenance=resolved!=null?"static-scan:resolved":"static-scan:unresolved";
                var dst=resolved??target;
                using var e=c.CreateCommand();e.Transaction=tx;e.CommandText="INSERT INTO edges(src,dst,kind,weight,provenance,dst_resolved,updated_utc) VALUES($s,$d,$k,1,$pv,$r,$u) ON CONFLICT(src,dst,kind) DO UPDATE SET provenance=excluded.provenance,dst_resolved=excluded.dst_resolved,updated_utc=excluded.updated_utc";
                e.Parameters.AddWithValue("$s",rel);e.Parameters.AddWithValue("$d",dst);e.Parameters.AddWithValue("$k",kind);e.Parameters.AddWithValue("$pv",provenance);e.Parameters.AddWithValue("$r",(object?)resolved??DBNull.Value);e.Parameters.AddWithValue("$u",now);
                edgeCount+=e.ExecuteNonQuery();
            }
        }
        var existing=new List<string>();using(var q=c.CreateCommand()){q.Transaction=tx;q.CommandText="SELECT path FROM files";using var r=q.ExecuteReader();while(r.Read())existing.Add(r.GetString(0));}
        foreach(var p in existing.Where(p=>!seen.Contains(p))){using var d=c.CreateCommand();d.Transaction=tx;d.CommandText="DELETE FROM files WHERE path=$p;DELETE FROM symbols WHERE path=$p;DELETE FROM edges WHERE src=$p OR dst=$p";d.Parameters.AddWithValue("$p",p);d.ExecuteNonQuery();}
        tx.Commit(); NormalizeInternal(c);
        return Emit(new{ok=true,files=seen.Count,changed,unchangedSkipped,symbols=symbolCount,edges=edgeCount,db=DbPath(project)});
    }
    static string[] Split(string s)=>s.Split(new[]{',',';','\n','\r'},StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    static int AddLesson(string project,string title,string body,string tags,string paths,string source,double confidence)
    {
        if(string.IsNullOrWhiteSpace(body))throw new ArgumentException("lesson body required"); if(string.IsNullOrWhiteSpace(title))title=body.Length>80?body[..80]:body;
        using var c=Open(project);var id="lesson-"+Guid.NewGuid().ToString("N")[..12];var now=DateTimeOffset.UtcNow.ToString("O");
        using var tx=c.BeginTransaction();using(var q=c.CreateCommand()){q.Transaction=tx;q.CommandText="INSERT INTO lessons(id,title,body,status,confidence,source,created_utc,updated_utc,last_confirmed_utc) VALUES($i,$t,$b,'active',$c,$s,$u,$u,$u)";q.Parameters.AddWithValue("$i",id);q.Parameters.AddWithValue("$t",title);q.Parameters.AddWithValue("$b",body);q.Parameters.AddWithValue("$c",Math.Clamp(confidence,0,1));q.Parameters.AddWithValue("$s",source);q.Parameters.AddWithValue("$u",now);q.ExecuteNonQuery();}
        foreach(var tag in Split(tags)){using var q=c.CreateCommand();q.Transaction=tx;q.CommandText="INSERT OR IGNORE INTO lesson_tags VALUES($i,$t)";q.Parameters.AddWithValue("$i",id);q.Parameters.AddWithValue("$t",tag.ToLowerInvariant());q.ExecuteNonQuery();}
        foreach(var path in Split(paths).Select(p=>p.Replace('\\','/'))){string? hash=null;using(var h=c.CreateCommand()){h.Transaction=tx;h.CommandText="SELECT sha256 FROM files WHERE path=$p";h.Parameters.AddWithValue("$p",path);hash=h.ExecuteScalar() as string;}using var q=c.CreateCommand();q.Transaction=tx;q.CommandText="INSERT OR REPLACE INTO lesson_paths VALUES($i,$p,$h)";q.Parameters.AddWithValue("$i",id);q.Parameters.AddWithValue("$p",path);q.Parameters.AddWithValue("$h",(object?)hash??DBNull.Value);q.ExecuteNonQuery();}
        tx.Commit();return Emit(new{ok=true,id});
    }
    static int ConfirmLesson(string project,string id,string note)=>SetLesson(project,id,"active",note,true);
    static int RejectLesson(string project,string id,string note)=>SetLesson(project,id,"rejected",note,false);
    static int SetLesson(string project,string id,string status,string note,bool confirm)
    {
        using var c=Open(project);using var q=c.CreateCommand();q.CommandText="UPDATE lessons SET status=$s,normalization_note=$n,updated_utc=$u,last_confirmed_utc=CASE WHEN $c=1 THEN $u ELSE last_confirmed_utc END WHERE id=$i";q.Parameters.AddWithValue("$s",status);q.Parameters.AddWithValue("$n",note);q.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));q.Parameters.AddWithValue("$c",confirm?1:0);q.Parameters.AddWithValue("$i",id);var n=q.ExecuteNonQuery();return Emit(new{ok=n>0,id,status});
    }
    static int Normalize(string project){using var c=Open(project);var n=NormalizeInternal(c);return Emit(new{ok=true,reviewRequired=n});}
    static int NormalizeInternal(SqliteConnection c)
    {
        using var q=c.CreateCommand();q.CommandText=@"UPDATE lessons SET status='needs_review',normalization_note='A linked file changed since this lesson was confirmed; re-check against the current project graph.',updated_utc=$u WHERE status='active' AND id IN (SELECT lp.lesson_id FROM lesson_paths lp LEFT JOIN files f ON f.path=lp.path WHERE lp.file_sha IS NOT NULL AND (f.sha256 IS NULL OR f.sha256<>lp.file_sha)); SELECT changes();";q.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));return Convert.ToInt32(q.ExecuteScalar());
    }
    static int Query(string project,string text,string paths,int limit)
    {
        using var c=Open(project);var terms=Split(Regex.Replace(text.ToLowerInvariant(),@"[^a-z0-9_./-]+",",")).Where(x=>x.Length>2).Take(12).ToArray();var ps=Split(paths).Select(x=>x.Replace('\\','/')).ToArray();
        var rows=new List<object>();using var q=c.CreateCommand();var where=new List<string>{"l.status<>'rejected'"};int i=0;
        if(terms.Length>0){var termOr=new List<string>();foreach(var t in terms){var p="$t"+i++;termOr.Add($"(lower(l.title) LIKE {p} OR lower(l.body) LIKE {p} OR EXISTS(SELECT 1 FROM lesson_tags ltx WHERE ltx.lesson_id=l.id AND lower(ltx.tag) LIKE {p}))");q.Parameters.AddWithValue(p,"%"+t+"%");}where.Add("("+string.Join(" OR ",termOr)+")");}
        if(ps.Length>0){var ors=new List<string>();foreach(var pth in ps){var p="$p"+i++;ors.Add($"lp.path LIKE {p}");q.Parameters.AddWithValue(p,pth.TrimEnd('*')+"%");}where.Add($"(EXISTS(SELECT 1 FROM lesson_paths lp WHERE lp.lesson_id=l.id AND ({string.Join(" OR ",ors)})) OR NOT EXISTS(SELECT 1 FROM lesson_paths lp2 WHERE lp2.lesson_id=l.id))");}
        q.CommandText=$"SELECT l.id,l.title,l.body,l.status,l.confidence,l.source,l.updated_utc,COALESCE(group_concat(DISTINCT lt.tag),'') tags,COALESCE(group_concat(DISTINCT lp.path),'') paths FROM lessons l LEFT JOIN lesson_tags lt ON lt.lesson_id=l.id LEFT JOIN lesson_paths lp ON lp.lesson_id=l.id WHERE {string.Join(" AND ",where)} GROUP BY l.id ORDER BY CASE l.status WHEN 'active' THEN 0 WHEN 'needs_review' THEN 1 ELSE 2 END,l.confidence DESC,l.updated_utc DESC LIMIT $lim";q.Parameters.AddWithValue("$lim",Math.Clamp(limit,1,50));
        using var r=q.ExecuteReader();while(r.Read())rows.Add(new{id=r.GetString(0),title=r.GetString(1),body=r.GetString(2),status=r.GetString(3),confidence=r.GetDouble(4),source=r.IsDBNull(5)?null:r.GetString(5),updatedUtc=r.GetString(6),tags=Split(r.GetString(7)),paths=Split(r.GetString(8))});
        return Emit(new{ok=true,lessons=rows});
    }
    static int Neighbors(string project,string path,int depth,int limit)
    {
        using var c=Open(project);var frontier=new HashSet<string>(StringComparer.OrdinalIgnoreCase){path.Replace('\\','/')};var all=new HashSet<string>(frontier,StringComparer.OrdinalIgnoreCase);var outEdges=new List<object>();
        for(int d=0;d<Math.Clamp(depth,1,4);d++){var next=new HashSet<string>(StringComparer.OrdinalIgnoreCase);foreach(var n in frontier){using var q=c.CreateCommand();q.CommandText="SELECT src,dst,kind,weight,provenance,dst_resolved FROM edges WHERE src=$n OR dst=$n LIMIT $l";q.Parameters.AddWithValue("$n",n);q.Parameters.AddWithValue("$l",limit);using var r=q.ExecuteReader();while(r.Read()){var s=r.GetString(0);var t=r.GetString(1);outEdges.Add(new{src=s,dst=t,kind=r.GetString(2),weight=r.GetDouble(3),provenance=r.IsDBNull(4)?null:r.GetString(4),resolved=r.IsDBNull(5)?null:r.GetString(5)});if(all.Add(s))next.Add(s);if(all.Add(t))next.Add(t);}}frontier=next;if(frontier.Count==0)break;}
        return Emit(new{ok=true,nodes=all.Take(limit),edges=outEdges.Take(limit)});
    }
    static int Status(string project)
    {
        using var c=Open(project);long Count(string table){using var q=c.CreateCommand();q.CommandText=$"SELECT count(*) FROM {table}";return Convert.ToInt64(q.ExecuteScalar());}
        using var stale=c.CreateCommand();stale.CommandText="SELECT count(*) FROM lessons WHERE status='needs_review'";return Emit(new{ok=true,db=DbPath(project),files=Count("files"),symbols=Count("symbols"),edges=Count("edges"),lessons=Count("lessons"),needsReview=Convert.ToInt64(stale.ExecuteScalar()),schemaVersion=SchemaVersion});
    }
}
