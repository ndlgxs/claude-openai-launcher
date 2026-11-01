// Node 18+. Default mode is local-only and loads no real credentials.
// node verify-effort.mjs --proxy-binary <cli-proxy-api.exe> --output-dir <private-directory>
// Optional --live-runtime <runtime.json> performs exactly two short Sol routing checks.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';

const options={};
for(let i=2;i<process.argv.length;i+=2) options[process.argv[i]]=process.argv[i+1];
if(!options['--proxy-binary'] || !options['--output-dir']) throw new Error('--proxy-binary and --output-dir are required.');
const proxyBinary=path.resolve(options['--proxy-binary']);
const outputRoot=path.resolve(options['--output-dir']);
if(!fs.existsSync(proxyBinary))throw new Error('The requested proxy binary does not exist.');
fs.mkdirSync(outputRoot,{recursive:true});
const authRoot=path.join(outputRoot,'empty-auth');fs.mkdirSync(authRoot,{recursive:true});
if(fs.readdirSync(authRoot).length) throw new Error('The isolated auth directory must be empty.');
const levels=['low','medium','high','xhigh','max'];
const routes=[['local-claude-sol','gpt-6.1-sol'],['local-claude-astra','gpt-6-astra'],['local-claude-terra','gpt-6.1-terra'],['local-claude-luna','gpt-6-luna']];
const clientKey='local-client-'+crypto.randomBytes(16).toString('hex');
const upstreamRequests=[];
const syntheticText='EFFORT_PROBE_OK';

function directHttp(url,{method='GET',headers={},body=null,timeout=15000}={}) {
  return new Promise((resolve,reject)=>{
    const req=http.request(url,{method,headers,agent:false},res=>{
      let text='';res.setEncoding('utf8');res.on('data',chunk=>text+=chunk);
      res.on('end',()=>resolve({status:res.statusCode,text,contentType:res.headers['content-type']}));
      res.on('error',reject);
    });
    req.setTimeout(timeout,()=>req.destroy(new Error('local request timeout')));
    req.on('error',reject);if(body!==null)req.write(body);req.end();
  });
}
function anthropicResult(response) {
  let text='',model=null,completed=false,errorType=null;
  for(const frame of response.text.replace(/\r\n/g,'\n').split('\n\n')) {
    const lines=frame.split('\n').filter(line=>line.startsWith('data:')).map(line=>line.slice(5).trimStart());
    if(!lines.length)continue;
    let event;try{event=JSON.parse(lines.join('\n'));}catch{continue;}
    if(event.type==='message_start')model=event.message?.model ?? null;
    if(event.type==='content_block_start' && event.content_block?.type==='text')text+=event.content_block.text ?? '';
    if(event.type==='content_block_delta' && event.delta?.type==='text_delta')text+=event.delta.text ?? '';
    if(event.type==='message_stop')completed=true;
    if(event.type==='error')errorType=event.error?.type ?? 'stream_error';
  }
  return {httpStatus:response.status,model,text,completed,errorType};
}
async function freePort() {
  const server=http.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port;await new Promise(resolve=>server.close(resolve));return port;
}
function sendResponsesStream(res,payload) {
  const id='resp_'+crypto.randomBytes(6).toString('hex');
  const item={id:'msg_'+id,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:syntheticText,annotations:[]}]};
  const response={id,object:'response',created_at:Math.floor(Date.now()/1000),status:'completed',model:payload.model,output:[item],usage:{input_tokens:10,output_tokens:5,total_tokens:15,output_tokens_details:{reasoning_tokens:0}}};
  const events=[
    {type:'response.created',response:{...response,status:'in_progress',output:[]}},
    {type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress',content:[]}},
    {type:'response.content_part.added',output_index:0,item_id:item.id,content_index:0,part:{type:'output_text',text:'',annotations:[]}},
    {type:'response.output_text.delta',output_index:0,item_id:item.id,content_index:0,delta:syntheticText},
    {type:'response.output_text.done',output_index:0,item_id:item.id,content_index:0,text:syntheticText},
    {type:'response.content_part.done',output_index:0,item_id:item.id,content_index:0,part:item.content[0]},
    {type:'response.output_item.done',output_index:0,item},
    {type:'response.completed',response}
  ];
  res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-cache'});
  for(const event of events)res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  res.end();
}
const mock=http.createServer((req,res)=>{
  let body='';req.setEncoding('utf8');req.on('data',chunk=>body+=chunk);req.on('end',()=>{
    let payload={};try{payload=JSON.parse(body);}catch{}
    const route=new URL(req.url,'http://127.0.0.1').pathname;
    upstreamRequests.push({route,model:payload.model ?? null,reasoningEffort:payload.reasoning?.effort ?? null});
    body='';
    if(!route.endsWith('/responses')){res.writeHead(404);return res.end('{}');}
    sendResponsesStream(res,payload);
  });
});
await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));
const mockPort=mock.address().port;
const proxyPort=await freePort();
const yamlQuote=value=>JSON.stringify(value.replaceAll('\\','/'));
const config=[
  'config-version: 8','server:','  host: "127.0.0.1"',`  port: ${proxyPort}`,
  'access:','  api-keys:',`    - ${JSON.stringify(clientKey)}`,
  'management:','  allow-remote: false','  secret-key: ""','  disable-control-panel: true',
  'oauth:',`  auth-dir: ${yamlQuote(authRoot)}`,
  'api-keys:','  codex:','    - name: isolated-effort-probe',`      base-url: "http://127.0.0.1:${mockPort}"`,'      proxy-url: direct','      request-retry: 0','      models:',
  ...routes.flatMap(([alias,source])=>[`        - name: "${source}"`,`          alias: "${alias}"`,'          force-mapping: true','          thinking:',`            levels: [${levels.map(level=>JSON.stringify(level)).join(', ')}]`]),
  '      keys:','        - api-key: "local-upstream-test-only"','          disable-codex-cloaking: true','          websockets: false',
  'plugins:','  enabled: false','observability:','  logs:','    debug: false','    request-log: false','    error-logs-max-files: 0'
].join('\n')+'\n';
const configPath=path.join(outputRoot,'isolated.config.yaml');fs.writeFileSync(configPath,config);
const childEnv={...process.env};
for(const name of Object.keys(childEnv))if(/^(OPENAI_|ANTHROPIC_|GEMINI_|GOOGLE_|AWS_|AZURE_|GITSTORE_|PGSTORE_|OBJECTSTORE_)/i.test(name) || /proxy$/i.test(name)) delete childEnv[name];
const child=spawn(proxyBinary,['--config',configPath,'--local-model'],{cwd:outputRoot,env:childEnv,windowsHide:true,stdio:['ignore','pipe','pipe']});
let proxyOutput='';child.stdout.on('data',chunk=>proxyOutput+=chunk);child.stderr.on('data',chunk=>proxyOutput+=chunk);
const pidEvidence={pid:child.pid,executablePath:proxyBinary,configPath,isolatedProxyPort:proxyPort,isolatedMockPort:mockPort,stopped:false};
fs.writeFileSync(path.join(outputRoot,'isolated-process.json'),JSON.stringify(pidEvidence,null,2));
const report={testKind:'Isolated real CLIProxyAPI binary -> local Responses mock; no real credential or upstream inference',proxyBinary,proxyPort,mockPort,levels,startedAt:new Date().toISOString(),cases:[],liveRoutingChecks:[],sources:{suffix:'https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.48/internal/thinking/suffix.go',validation:'https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.48/internal/thinking/validate.go',codexApplier:'https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.48/internal/thinking/provider/codex/apply.go'}};
try {
  let ready=false;
  for(let attempt=0;attempt<60;attempt++) {
    if(child.exitCode!==null)throw new Error('Isolated proxy exited before readiness.');
    try{const response=await directHttp(`http://127.0.0.1:${proxyPort}/v1/models`,{headers:{Authorization:`Bearer ${clientKey}`},timeout:500});if(response.status===200){ready=true;break;}}catch{}
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  if(!ready)throw new Error('Isolated proxy did not become ready.');
  for(const [alias,sourceModel] of routes)for(const level of levels) {
    const requestedModel=`${alias}(${level})`;
    const before=upstreamRequests.length;
    const response=await directHttp(`http://127.0.0.1:${proxyPort}/v1/messages`,{method:'POST',headers:{'content-type':'application/json','x-api-key':clientKey,'anthropic-version':'2023-06-01'},body:JSON.stringify({model:requestedModel,max_tokens:64,stream:true,messages:[{role:'user',content:'Reply with EFFORT_PROBE_OK.'}]})});
    const parsed=anthropicResult(response);
    const observed=upstreamRequests.slice(before);
    const passed=parsed.httpStatus===200 && parsed.completed && !parsed.errorType && parsed.text===syntheticText && observed.length===1 && observed[0].model===sourceModel && observed[0].reasoningEffort===level;
    report.cases.push({requestedModel,sourceModel,requestedEffort:level,observedUpstreamRequests:observed,responseModel:parsed.model,httpStatus:parsed.httpStatus,streamCompleted:parsed.completed,textMatched:parsed.text===syntheticText,errorType:parsed.errorType,passed});
  }
  report.allFiveEffortsDistinctPassed=report.cases.length===20 && report.cases.every(test=>test.passed);
  if(options['--live-runtime']) {
    const runtime=JSON.parse(fs.readFileSync(path.resolve(options['--live-runtime']),'utf8').replace(/^\uFEFF/,''));
    for(const level of ['low','high']) {
      const marker=`LIVE_SUFFIX_${level}_${crypto.randomBytes(4).toString('hex')}`;
      const requestedModel=`local-claude-sol(${level})`;
      const response=await directHttp(`http://127.0.0.1:${runtime.port}/v1/messages`,{method:'POST',headers:{'content-type':'application/json','x-api-key':runtime.proxyKey,'anthropic-version':'2023-06-01'},body:JSON.stringify({model:requestedModel,max_tokens:64,stream:true,messages:[{role:'user',content:`Reply with exactly ${marker}.`}]}),timeout:45000});
      const parsed=anthropicResult(response);
      report.liveRoutingChecks.push({requestedModel,responseModel:parsed.model,httpStatus:parsed.httpStatus,streamCompleted:parsed.completed,textMatched:parsed.text.trim()===marker,errorType:parsed.errorType,passed:parsed.httpStatus===200 && parsed.completed && !parsed.errorType && parsed.text.trim()===marker,reasoningEvidence:'Routing success only; actual upstream effort is established by the isolated mock capture, not by this live response.'});
    }
  }
}catch(error){report.failure=error.message;}
finally {
  // This handle belongs only to the child spawned above; never look up or stop another proxy.
  if(child.exitCode===null){child.kill();await new Promise(resolve=>child.once('close',resolve));}
  await new Promise(resolve=>mock.close(resolve));
  pidEvidence.stopped=true;fs.writeFileSync(path.join(outputRoot,'isolated-process.json'),JSON.stringify(pidEvidence,null,2));
  report.finishedAt=new Date().toISOString();report.isolatedProcessStopped=true;
  report.proxyVersion=proxyOutput.match(/CLIProxyAPI Version:\s*([^,\r\n]+)/)?.[1] ?? null;
  fs.writeFileSync(path.join(outputRoot,'proxy.log'),proxyOutput.replaceAll(clientKey,'<local-test-key>'));
  fs.writeFileSync(path.join(outputRoot,'effort-results.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({caseCount:report.cases.length,allFiveEffortsDistinctPassed:report.allFiveEffortsDistinctPassed ?? false,liveRoutingChecks:report.liveRoutingChecks,isolatedProcessStopped:report.isolatedProcessStopped,failure:report.failure ?? null,failedCases:report.cases.filter(test=>!test.passed)}));
if(!report.allFiveEffortsDistinctPassed || report.failure || report.liveRoutingChecks.some(test=>!test.passed))process.exitCode=1;
