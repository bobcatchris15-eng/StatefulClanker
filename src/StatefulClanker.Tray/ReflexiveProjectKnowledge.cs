using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StatefulClanker.Tray;

static class ReflexiveProjectKnowledge
{
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
        Ensure(c); return c;
    }
    static void Ensure(SqliteConnection c)
    {
        using var q=c.CreateCommand(); q.CommandText=@"
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,sha256 TEXT NOT NULL,size INTEGER NOT NULL,mtime_utc TEXT NOT NULL,language TEXT,updated_utc TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS symbols(id INTEGER PRIMARY KEY AUTOINCREMENT,path TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,line INTEGER NOT NULL,signature TEXT,UNIQUE(path,name,kind,line));
CREATE INDEX IF NOT EXISTS ix_symbols_name ON symbols(name);
CREATE TABLE IF NOT EXISTS edges(src TEXT NOT NULL,dst TEXT NOT NULL,kind TEXT NOT NULL,weight REAL NOT NULL DEFAULT 1,provenance TEXT,updated_utc TEXT NOT NULL,PRIMARY KEY(src,dst,kind));
CREATE INDEX IF NOT EXISTS ix_edges_dst ON edges(dst);
CREATE TABLE IF NOT EXISTS lessons(id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'active',confidence REAL NOT NULL DEFAULT .75,source TEXT,created_utc TEXT NOT NULL,updated_utc TEXT NOT NULL,last_confirmed_utc TEXT,normalization_note TEXT);
CREATE TABLE IF NOT EXISTS lesson_tags(lesson_id TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(lesson_id,tag),FOREIGN KEY(lesson_id) REFERENCES lessons(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS ix_lesson_tags_tag ON lesson_tags(tag);
CREATE TABLE IF NOT EXISTS lesson_paths(lesson_id TEXT NOT NULL,path TEXT NOT NULL,file_sha TEXT,PRIMARY KEY(lesson_id,path),FOREIGN KEY(lesson_id) REFERENCES lessons(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS ix_lesson_paths_path ON lesson_paths(path);
"; q.ExecuteNonQuery();
    }
    static int Init(string project){using var c=Open(project);return Emit(new{ok=true,project,db=DbPath(project)});}
    static string Rel(string root,string full)=>Path.GetRelativePath(root,full).Replace('\\','/');
    static bool Ignored(string root,string full)
    {
        var rel=Rel(root,full); return rel.Split('/').Any(p=>IgnoredDirs.Contains(p)) || rel.StartsWith(".clanker/",StringComparison.OrdinalIgnoreCase);
    }
    static string Sha(string path){using var s=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant();}
    static string Lang(string path)=>Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
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
    static int Index(string project)
    {
        using var c=Open(project); using var tx=c.BeginTransaction(); var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);int changed=0,symbols=0,edges=0;
        foreach(var full in Directory.EnumerateFiles(project,"*",SearchOption.AllDirectories))
        {
            if(Ignored(project,full)||!TextExt.Contains(Path.GetExtension(full)))continue;
            var fi=new FileInfo(full);if(fi.Length>2_000_000)continue;var rel=Rel(project,full);seen.Add(rel);var sha=Sha(full);
            using(var chk=c.CreateCommand()){chk.Transaction=tx;chk.CommandText="SELECT sha256 FROM files WHERE path=$p";chk.Parameters.AddWithValue("$p",rel);var old=chk.ExecuteScalar() as string;if(old==sha)continue;}
            changed++;
            using(var up=c.CreateCommand()){up.Transaction=tx;up.CommandText="INSERT INTO files(path,sha256,size,mtime_utc,language,updated_utc) VALUES($p,$h,$s,$m,$l,$u) ON CONFLICT(path) DO UPDATE SET sha256=excluded.sha256,size=excluded.size,mtime_utc=excluded.mtime_utc,language=excluded.language,updated_utc=excluded.updated_utc";up.Parameters.AddWithValue("$p",rel);up.Parameters.AddWithValue("$h",sha);up.Parameters.AddWithValue("$s",fi.Length);up.Parameters.AddWithValue("$m",fi.LastWriteTimeUtc.ToString("O"));up.Parameters.AddWithValue("$l",Lang(full));up.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));up.ExecuteNonQuery();}
            using(var del=c.CreateCommand()){del.Transaction=tx;del.CommandText="DELETE FROM symbols WHERE path=$p; DELETE FROM edges WHERE src=$p AND kind='references';";del.Parameters.AddWithValue("$p",rel);del.ExecuteNonQuery();}
            foreach(var s in ExtractSymbols(full)){using var ins=c.CreateCommand();ins.Transaction=tx;ins.CommandText="INSERT OR IGNORE INTO symbols(path,name,kind,line,signature) VALUES($p,$n,$k,$l,$s)";ins.Parameters.AddWithValue("$p",rel);ins.Parameters.AddWithValue("$n",s.name);ins.Parameters.AddWithValue("$k",s.kind);ins.Parameters.AddWithValue("$l",s.line);ins.Parameters.AddWithValue("$s",s.sig);symbols+=ins.ExecuteNonQuery();}
            foreach(var r in ExtractRefs(full).Distinct(StringComparer.OrdinalIgnoreCase)){using var e=c.CreateCommand();e.Transaction=tx;e.CommandText="INSERT INTO edges(src,dst,kind,weight,provenance,updated_utc) VALUES($s,$d,'references',1,'static-scan',$u) ON CONFLICT(src,dst,kind) DO UPDATE SET updated_utc=excluded.updated_utc";e.Parameters.AddWithValue("$s",rel);e.Parameters.AddWithValue("$d",r.Replace('\\','/'));e.Parameters.AddWithValue("$u",DateTimeOffset.UtcNow.ToString("O"));edges+=e.ExecuteNonQuery();}
        }
        var existing=new List<string>();using(var q=c.CreateCommand()){q.Transaction=tx;q.CommandText="SELECT path FROM files";using var r=q.ExecuteReader();while(r.Read())existing.Add(r.GetString(0));}
        foreach(var p in existing.Where(p=>!seen.Contains(p))){using var d=c.CreateCommand();d.Transaction=tx;d.CommandText="DELETE FROM files WHERE path=$p;DELETE FROM symbols WHERE path=$p;DELETE FROM edges WHERE src=$p OR dst=$p";d.Parameters.AddWithValue("$p",p);d.ExecuteNonQuery();}
        tx.Commit(); NormalizeInternal(c); return Emit(new{ok=true,files=seen.Count,changed,symbols,edges,db=DbPath(project)});
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
        for(int d=0;d<Math.Clamp(depth,1,4);d++){var next=new HashSet<string>(StringComparer.OrdinalIgnoreCase);foreach(var n in frontier){using var q=c.CreateCommand();q.CommandText="SELECT src,dst,kind,weight FROM edges WHERE src=$n OR dst=$n LIMIT $l";q.Parameters.AddWithValue("$n",n);q.Parameters.AddWithValue("$l",limit);using var r=q.ExecuteReader();while(r.Read()){var s=r.GetString(0);var t=r.GetString(1);outEdges.Add(new{src=s,dst=t,kind=r.GetString(2),weight=r.GetDouble(3)});if(all.Add(s))next.Add(s);if(all.Add(t))next.Add(t);}}frontier=next;if(frontier.Count==0)break;}
        return Emit(new{ok=true,nodes=all.Take(limit),edges=outEdges.Take(limit)});
    }
    static int Status(string project)
    {
        using var c=Open(project);long Count(string table){using var q=c.CreateCommand();q.CommandText=$"SELECT count(*) FROM {table}";return Convert.ToInt64(q.ExecuteScalar());}
        using var stale=c.CreateCommand();stale.CommandText="SELECT count(*) FROM lessons WHERE status='needs_review'";return Emit(new{ok=true,db=DbPath(project),files=Count("files"),symbols=Count("symbols"),edges=Count("edges"),lessons=Count("lessons"),needsReview=Convert.ToInt64(stale.ExecuteScalar())});
    }
}
