param([Parameter(Mandatory)][string]$Repository)
$ErrorActionPreference = 'Stop'
$queueSource = [IO.File]::ReadAllText((Join-Path $Repository 'src/Listener/Utilities/PodeItemQueue.cs'))
Add-Type -TypeDefinition ($queueSource + @"
public class HttpAcquireListenerFixture {
 public Pode.Utilities.PodeItemQueue<int> Queue = new Pode.Utilities.PodeItemQueue<int>();
 public int Started;
 public int GetContext(System.Threading.CancellationToken token) {
  System.Threading.Interlocked.Increment(ref Started); return Queue.Get(token);
 }
 public System.Threading.Tasks.Task<int> GetContextAsync(System.Threading.CancellationToken token) {
  System.Threading.Interlocked.Increment(ref Started); return Queue.GetAsync(token);
 }
 public System.Threading.Tasks.Task Send() { return System.Threading.Tasks.Task.Run(() => Queue.Add(7)); }
}
"@)
# Execute the actual HTTP worker acquisition, not a copy of its implementation.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'src/Private/PodeServer.ps1'), [ref]$null, [ref]$null)
$acquire = @($ast.FindAll({ param($n)
 $n -is [Management.Automation.Language.AssignmentStatementAst] -and
 $n.Left.Extent.Text -eq '$context' -and $n.Right.Extent.Text -match '\$Listener\.GetContext'
}, $true))
if ($acquire.Count -ne 1) { throw 'Expected one HTTP context acquisition' }
$waitFunctions = foreach ($file in 'src/Public/Tasks.ps1','src/Private/Tasks.ps1') {
 $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository $file), [ref]$null, [ref]$null)
 $tree.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Wait-PodeTask','Wait-PodeTaskNetInternal') }, $true) | ForEach-Object { $_.Extent.Text }
}
$readerScript = 'param($Listener,$PodeContext)' + "`n" + ($waitFunctions -join "`n") + "`n" + 'try {' + "`n" + $acquire[0].Extent.Text + "`n" + '$context } catch [System.OperationCanceledException] { "CANCELLED" }'
$listener = [HttpAcquireListenerFixture]::new()
$cancel = [Threading.CancellationTokenSource]::new()
$context = @{ Tokens = @{ Cancellation = $cancel } }
$readers = @()
$maxWorkers = 0; $maxIo = 0; $minWorkers = 0; $minIo = 0
[Threading.ThreadPool]::GetMaxThreads([ref]$maxWorkers,[ref]$maxIo)
[Threading.ThreadPool]::GetMinThreads([ref]$minWorkers,[ref]$minIo)
try {
 foreach ($i in 1..16) {
  $ps = [PowerShell]::Create()
  $null = $ps.AddScript($readerScript).AddArgument($listener).AddArgument($context)
  $readers += @{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
 }
 $ready = [Diagnostics.Stopwatch]::StartNew()
 while ($listener.Started -lt 16 -and $ready.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 10 }
 if ($listener.Started -ne 16) { throw "Only $($listener.Started) worker acquisitions started" }
 # Deliberately constrain this throwaway process only: a queued socket producer
 # must run even with sixteen idle dedicated HTTP workers waiting for requests.
 if (-not [Threading.ThreadPool]::SetMinThreads(2,$minIo)) { throw 'Could not set fixture minimum' }
 if (-not [Threading.ThreadPool]::SetMaxThreads(2,$maxIo)) { throw 'Could not cap fixture pool' }
 $send = $listener.Send()
 $timer = [Diagnostics.Stopwatch]::StartNew()
 while (-not $send.IsCompleted -and $timer.ElapsedMilliseconds -lt 1500) { Start-Sleep -Milliseconds 10 }
 $producerCompleted = $send.IsCompleted
 while ($producerCompleted -and -not @($readers | Where-Object { $_.Handle.IsCompleted }).Count -and $timer.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
 $cancel.Cancel()
 $null = [Threading.ThreadPool]::SetMaxThreads($maxWorkers,$maxIo)
 $received = 0; $cancelled = 0
 foreach ($r in $readers) {
  if (-not $r.Handle.AsyncWaitHandle.WaitOne(5000)) { throw 'Worker did not stop after cancellation' }
  try { foreach ($item in $r.PowerShell.EndInvoke($r.Handle)) { if ($item -eq 7) { $received++ } elseif ($item -eq "CANCELLED") { $cancelled++ } } }
  catch { if ($_.Exception.ToString() -notmatch 'OperationCanceledException|TaskCanceledException') { throw }; $cancelled++ }
 }
 $send.GetAwaiter().GetResult()
 $processing = $listener.Queue.ProcessingCount
 $listener.Queue.RemoveProcessing(7)
 $remainingProcessing = $listener.Queue.ProcessingCount
 $listener.Queue.Dispose()
 $disposedResult = & ([scriptblock]::Create($readerScript)) $listener $context
 [pscustomobject]@{ producerCompleted=$producerCompleted; received=$received; cancelled=$cancelled; processing=$processing; remainingProcessing=$remainingProcessing; disposedResult=$disposedResult } | ConvertTo-Json -Compress
}
finally {
 $cancel.Cancel()
 $null = [Threading.ThreadPool]::SetMaxThreads($maxWorkers,$maxIo)
 $null = [Threading.ThreadPool]::SetMinThreads($minWorkers,$minIo)
 foreach ($r in $readers) { $r.PowerShell.Dispose() }
 $cancel.Dispose()
}
