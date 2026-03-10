#!/usr/bin/env node
var https=require('https'),fs=require('fs'),path=require('path'),readline=require('readline'),os=require('os'),cp=require('child_process');
var VERSION='2.1.71-sl',API='api.anthropic.com',KEY=process.env.ANTHROPIC_API_KEY||'';
if(!KEY)try{KEY=fs.readFileSync(path.join(os.homedir(),'.anthropic_key'),'utf8').trim()}catch(e){}
var args=process.argv.slice(2),pm=false,prompt=null,model='claude-sonnet-4-20250514',mt=8192,cwd=process.cwd();
for(var i=0;i<args.length;i++){
if(args[i]==='-p'||args[i]==='--print'){pm=true;if(args[i+1]&&args[i+1][0]!=='-')prompt=args[++i]}
else if(args[i]==='--model')model=args[++i];
else if(args[i]==='-v'||args[i]==='--version'){console.log(VERSION);process.exit(0)}
else if(args[i]==='-h'||args[i]==='--help'){console.log('Claude Code \u2014 Snow Leopard Edition\nUsage: claude [-p <prompt>] [--model <m>] [-v]');process.exit(0)}
else if(!prompt)prompt=args[i]}
if(!KEY){console.error('Error: No API key. Set ANTHROPIC_API_KEY or create ~/.anthropic_key');process.exit(1)}
var tools=[
{name:'read_file',description:'Read file contents',input_schema:{type:'object',properties:{path:{type:'string'},line_range:{type:'array',items:{type:'integer'}}},required:['path']}},
{name:'write_file',description:'Create or overwrite a file',input_schema:{type:'object',properties:{path:{type:'string'},content:{type:'string'}},required:['path','content']}},
{name:'edit_file',description:'Replace exact text in a file',input_schema:{type:'object',properties:{path:{type:'string'},old_text:{type:'string'},new_text:{type:'string'}},required:['path','old_text','new_text']}},
{name:'bash',description:'Run a bash command',input_schema:{type:'object',properties:{command:{type:'string'}},required:['command']}},
{name:'list_files',description:'List files (max 2 levels deep)',input_schema:{type:'object',properties:{path:{type:'string'}},required:['path']}},
{name:'grep',description:'Search for pattern in files',input_schema:{type:'object',properties:{pattern:{type:'string'},path:{type:'string'},include:{type:'string'}},required:['pattern']}}
];
function exec(n,inp){try{
if(n==='read_file'){var c=fs.readFileSync(path.resolve(cwd,inp.path),'utf8');if(inp.line_range){var l=c.split('\n'),s=(inp.line_range[0]||1)-1,e=inp.line_range[1]||l.length;c=l.slice(s,e).map(function(x,i){return(s+i+1)+'. '+x}).join('\n')}return c}
if(n==='write_file'){var p=path.resolve(cwd,inp.path);try{fs.mkdirSync(path.dirname(p),{recursive:true})}catch(e){}fs.writeFileSync(p,inp.content);return'Written: '+inp.path}
if(n==='edit_file'){var p=path.resolve(cwd,inp.path),c=fs.readFileSync(p,'utf8');if(c.indexOf(inp.old_text)===-1)return'Error: old_text not found';fs.writeFileSync(p,c.replace(inp.old_text,inp.new_text));return'Edited: '+inp.path}
if(n==='bash')return cp.execSync(inp.command,{cwd:cwd,encoding:'utf8',timeout:60000,maxBuffer:2*1024*1024,stdio:['pipe','pipe','pipe']});
if(n==='list_files')return cp.execSync('find '+JSON.stringify(path.resolve(cwd,inp.path||'.'))+' -maxdepth 2 -not -path "*/\\.*" 2>/dev/null | head -200',{encoding:'utf8',timeout:5000});
if(n==='grep'){return cp.execSync('grep -rn --include='+JSON.stringify(inp.include||'*')+' '+JSON.stringify(inp.pattern)+' '+JSON.stringify(path.resolve(cwd,inp.path||'.'))+' 2>/dev/null | head -50',{encoding:'utf8',timeout:10000})}
return'Unknown tool'}catch(e){return'Error: '+(e.stderr?e.stderr.toString().slice(0,500):e.message)}}
function api(msgs,cb){
var sys='You are Claude, an AI assistant by Anthropic, running natively on Mac OS X 10.6 Snow Leopard.\nYou are a coding agent with tools: read_file, write_file, edit_file, bash, list_files, grep.\nWorking directory: '+cwd+'\nUse tools to investigate before answering questions about code.';
var b=JSON.stringify({model:model,max_tokens:mt,system:sys,tools:tools,messages:msgs});
var r=https.request({hostname:API,port:443,path:'/v1/messages',method:'POST',headers:{'Content-Type':'application/json','x-api-key':KEY,'anthropic-version':'2023-06-01','Content-Length':Buffer.byteLength(b)}},function(res){var d='';res.on('data',function(c){d+=c});res.on('end',function(){try{cb(null,JSON.parse(d))}catch(e){cb(Error('Parse: '+d.slice(0,200)))}})});
r.on('error',cb);r.write(b);r.end()}
function loop(msgs,cb){api(msgs,function(e,r){
if(e)return cb(e);if(r.error)return cb(Error(r.error.message));
var tu=false;r.content.forEach(function(b){if(b.type==='text')process.stdout.write(b.text);if(b.type==='tool_use')tu=true});
if(r.stop_reason==='tool_use'&&tu){msgs.push({role:'assistant',content:r.content});var tr=[];
r.content.forEach(function(b){if(b.type==='tool_use'){process.stderr.write('\n  \x1b[36m\u26A1 '+b.name+'\x1b[0m');
if(b.input.command)process.stderr.write(' \x1b[2m'+b.input.command.slice(0,60)+'\x1b[0m');
else if(b.input.path)process.stderr.write(' \x1b[2m'+b.input.path+'\x1b[0m');
process.stderr.write('\n');var res=exec(b.name,b.input);tr.push({type:'tool_result',tool_use_id:b.id,content:res.slice(0,30000)})}});
msgs.push({role:'user',content:tr});loop(msgs,cb)}else{process.stdout.write('\n');cb(null,r)}})}
if(prompt){loop([{role:'user',content:prompt}],function(e){if(e){console.error('\x1b[31mError:\x1b[0m '+e.message);process.exit(1)}process.exit(0)})}
else{var rl=readline.createInterface({input:process.stdin,output:process.stderr}),msgs=[];
console.error('\n  \x1b[1m\u2726 claude\x1b[0m \x1b[2m(Snow Leopard Edition)\x1b[0m');
console.error('  \x1b[2mModel: '+model+'\x1b[0m');
console.error('  \x1b[2mDir:   '+cwd+'\x1b[0m\n');
function ask(){rl.question('\x1b[35m\u276F\x1b[0m ',function(inp){inp=inp.trim();
if(!inp)return ask();if(inp==='/quit')process.exit(0);
if(inp==='/help'){console.error('  /model <n>  /clear  /quit');return ask()}
if(inp.indexOf('/model ')===0){model=inp.slice(7).trim();console.error('\x1b[2mModel: '+model+'\x1b[0m');return ask()}
if(inp==='/clear'){msgs=[];console.error('\x1b[2mCleared.\x1b[0m');return ask()}
msgs.push({role:'user',content:inp});process.stderr.write('\n');
loop(msgs,function(e,r){if(e)console.error('\x1b[31mError:\x1b[0m '+e.message);else if(r)msgs.push({role:'assistant',content:r.content});console.error('');ask()})})}
ask()}
