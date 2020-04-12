VERSION 5.00
Begin VB.Form Form1 
   Caption         =   "Form1"
   ClientHeight    =   5568
   ClientLeft      =   108
   ClientTop       =   456
   ClientWidth     =   9948
   LinkTopic       =   "Form1"
   ScaleHeight     =   5568
   ScaleWidth      =   9948
   StartUpPosition =   3  'Windows Default
   Begin VB.TextBox txtResult 
      BeginProperty Font 
         Name            =   "Consolas"
         Size            =   10.2
         Charset         =   204
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      Height          =   4800
      Left            =   0
      MultiLine       =   -1  'True
      ScrollBars      =   2  'Vertical
      TabIndex        =   3
      Top             =   588
      Width           =   9756
   End
   Begin VB.CommandButton Command1 
      Caption         =   "Download"
      Default         =   -1  'True
      Height          =   348
      Left            =   8400
      TabIndex        =   2
      Top             =   168
      Width           =   1356
   End
   Begin VB.TextBox txtUrl 
      Height          =   348
      Left            =   1260
      TabIndex        =   0
      Text            =   "localhost:44330"
      Top             =   168
      Width           =   7068
   End
   Begin VB.Label Label1 
      Caption         =   "Address:"
      Height          =   348
      Left            =   168
      TabIndex        =   1
      Top             =   168
      Width           =   936
   End
End
Attribute VB_Name = "Form1"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
Option Explicit
DefObj A-Z

'=========================================================================
' API
'=========================================================================

'--- Windows Messages
Private Const WM_SETREDRAW              As Long = &HB
Private Const EM_SETSEL                 As Long = &HB1
Private Const EM_REPLACESEL             As Long = &HC2
Private Const WM_VSCROLL                As Long = &H115
'--- for WM_VSCROLL
Private Const SB_BOTTOM                 As Long = 7

Private Declare Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" (Destination As Any, Source As Any, ByVal Length As Long)
Private Declare Function ArrPtr Lib "msvbvm60" Alias "VarPtr" (Ptr() As Any) As Long
Private Declare Function GetModuleHandle Lib "kernel32" Alias "GetModuleHandleA" (ByVal lpModuleName As String) As Long
Private Declare Function LoadLibrary Lib "kernel32" Alias "LoadLibraryA" (ByVal lpLibFileName As String) As Long
Private Declare Function SendMessage Lib "user32" Alias "SendMessageA" (ByVal hWnd As Long, ByVal wMsg As Long, ByVal wParam As Long, lParam As Any) As Long
'--- libsodium
Private Declare Function sodium_init Lib "libsodium" () As Long

'=========================================================================
' Constants and member variables
'=========================================================================

Private m_oSocket           As cAsyncSocket
Private m_sServerName       As String
Private m_uCtx              As UcsTlsContext

Private Type UcsParsedUrl
    Protocol        As String
    Host            As String
    Port            As Long
    Path            As String
    User            As String
    Pass            As String
End Type

'=========================================================================
' Events
'=========================================================================

Private Sub Form_Load()
    If GetModuleHandle("libsodium.dll") = 0 Then
        Call LoadLibrary(App.Path & "\libsodium.dll")
        Call sodium_init
    End If
    If txtResult.Font.Name = "Arial" Then
        txtResult.Font.Name = "Courier New"
    End If
End Sub

Private Sub Form_Resize()
    If WindowState <> vbMinimized Then
        txtResult.Move 0, txtResult.Top, ScaleWidth, ScaleHeight - txtResult.Top
    End If
End Sub

Private Sub Command1_Click()
    Dim uRemote         As UcsParsedUrl
    Dim sResult         As String
    Dim sError          As String
    
    On Error GoTo EH
    ' tls13.1d.pw, localhost:44330, tls.ctf.network
    If Not ParseUrl(txtUrl.Text, uRemote, DefProtocol:="https") Then
        MsgBox "Wrong URL", vbCritical
        GoTo QH
    End If
    txtResult.Text = vbNullString
    sResult = HttpsRequest(m_uCtx, uRemote, sError)
    If LenB(sError) <> 0 Then
        pvAppendLogText txtResult, "Error: " & sError
        GoTo QH
    End If
    If LenB(sResult) <> 0 Then
        txtResult.Text = vbNullString
        pvAppendLogText txtResult, sResult
        txtResult.SelStart = 0
    End If
QH:
    Exit Sub
EH:
    MsgBox Err.Description & " [" & Err.Source & "]", vbCritical
    Set m_oSocket = Nothing
End Sub

'=========================================================================
' Methods
'=========================================================================

Private Function HttpsRequest(uCtx As UcsTlsContext, uRemote As UcsParsedUrl, sError As String) As String
    Dim baRecv()        As Byte
    Dim sRequest        As String
    Dim baSend()        As Byte
    Dim lSize           As Long
    Dim bComplete       As Boolean
    Dim baDecr()        As Byte
    Dim dblTimer        As Double
    
    txtResult.Text = vbNullString
    If m_sServerName <> uRemote.Host & ":" & uRemote.Port Or m_oSocket Is Nothing Then
        Set m_oSocket = New cAsyncSocket
        If Not m_oSocket.SyncConnect(uRemote.Host, uRemote.Port) Then
            sError = m_oSocket.GetErrorDescription(m_oSocket.LastError)
            GoTo QH
        End If
        m_sServerName = uRemote.Host & ":" & uRemote.Port
        '--- send TLS handshake
        uCtx = TlsInitClient(ServerName:=uRemote.Host) ' , SupportProtocols:=ucsTlsSupportTls12)
        GoTo InLoop
        Do
            If Not m_oSocket.SyncReceiveArray(baRecv, Timeout:=1000) Then
                sError = m_oSocket.GetErrorDescription(m_oSocket.LastError)
                GoTo QH
            End If
InLoop:
            If pvArraySize(baRecv) <> 0 Then
                pvAppendLogText txtResult, String$(2, ">") & " Recv " & pvArraySize(baRecv) & vbCrLf & DesignDumpMemory(VarPtr(baRecv(0)), pvArraySize(baRecv))
            End If
            lSize = 0
            If Not TlsHandshake(uCtx, baRecv, -1, baSend, lSize, bComplete) Then
                sError = TlsGetLastError(uCtx)
                GoTo QH
            End If
            If lSize > 0 Then
                pvAppendLogText txtResult, String$(2, "<") & " Send " & lSize & vbCrLf & DesignDumpMemory(VarPtr(baSend(0)), lSize)
                If Not m_oSocket.SyncSend(VarPtr(baSend(0)), lSize) Then
                    sError = m_oSocket.GetErrorDescription(m_oSocket.LastError)
                    GoTo QH
                End If
            End If
        Loop While Not bComplete
    End If
    '--- send TLS application data and wait for recv
    sRequest = "GET " & uRemote.Path & " HTTP/1.1" & vbCrLf & _
               "Connection: keep-alive" & vbCrLf & _
               "Host: " & uRemote.Host & vbCrLf & vbCrLf
    lSize = 0
    If Not TlsSend(uCtx, StrConv(sRequest, vbFromUnicode), -1, baSend, lSize) Then
        sError = TlsGetLastError(uCtx)
        GoTo QH
    End If
    If lSize > 0 Then
        pvAppendLogText txtResult, String$(2, "<") & " Send " & lSize & vbCrLf & DesignDumpMemory(VarPtr(baSend(0)), lSize)
        If Not m_oSocket.SyncSend(VarPtr(baSend(0)), lSize) Then
            sError = m_oSocket.GetErrorDescription(m_oSocket.LastError)
            GoTo QH
        End If
    End If
    lSize = 0
    dblTimer = Timer
    Do
        If Not m_oSocket.ReceiveArray(baRecv) Then
            sError = m_oSocket.GetErrorDescription(m_oSocket.LastError)
            GoTo QH
        End If
        If pvArraySize(baRecv) <> 0 Then
            pvAppendLogText txtResult, String$(2, ">") & " Recv " & pvArraySize(baRecv) & vbCrLf & DesignDumpMemory(VarPtr(baRecv(0)), pvArraySize(baRecv))
            dblTimer = Timer
        ElseIf lSize > 0 And Timer > dblTimer + 0.2 Then
            Exit Do
        ElseIf Timer > dblTimer + 1 Then
            Exit Do
        End If
        If Not TlsReceive(uCtx, baRecv, -1, baDecr, lSize) Then
            sError = TlsGetLastError(uCtx)
            GoTo QH
        End If
    Loop
    HttpsRequest = Replace(Replace(StrConv(baDecr, vbUnicode), vbCr, vbNullString), vbLf, vbCrLf)
    lSize = InStr(1, HttpsRequest, vbCrLf & vbCrLf)
    If lSize = 0 Then
        Set m_oSocket = Nothing
    ElseIf InStr(1, Left$(HttpsRequest, lSize), "Connection: close", vbTextCompare) Then
        Set m_oSocket = Nothing
    End If
QH:
    If LenB(sError) <> 0 Then
        Set m_oSocket = Nothing
    End If
End Function

Private Function ParseUrl(sUrl As String, uParsed As UcsParsedUrl, Optional DefProtocol As String) As Boolean
    With CreateObject("VBScript.RegExp")
        .Global = True
        .Pattern = "^(?:(.*)://)?(?:(?:([^:]*):)?([^@]*)@)?([A-Za-z0-9\-\.]+)(:[0-9]+)?(.*)$"
        With .Execute(sUrl)
            If .Count > 0 Then
                With .Item(0).SubMatches
                    uParsed.Protocol = .Item(0)
                    uParsed.User = .Item(1)
                    If LenB(uParsed.User) = 0 Then
                        uParsed.User = .Item(2)
                    Else
                        uParsed.Pass = .Item(2)
                    End If
                    uParsed.Host = .Item(3)
                    uParsed.Port = Val(Mid$(.Item(4), 2))
                    If uParsed.Port = 0 Then
                        Select Case LCase$(IIf(LenB(uParsed.Protocol) = 0, DefProtocol, uParsed.Protocol))
                        Case "https"
                            uParsed.Port = 443
                        Case "socks5"
                            uParsed.Port = 1080
                        Case Else
                            uParsed.Port = 80
                        End Select
                    End If
                    uParsed.Path = .Item(5)
                    If LenB(uParsed.Path) = 0 Then
                        uParsed.Path = "/"
                    End If
                End With
                ParseUrl = True
            End If
        End With
    End With
End Function

Private Function pvArraySize(baArray() As Byte, Optional RetVal As Long) As Long
    Dim lPtr            As Long
    
    '--- peek long at ArrPtr(baArray)
    Call CopyMemory(lPtr, ByVal ArrPtr(baArray), 4)
    If lPtr <> 0 Then
        RetVal = UBound(baArray) + 1
    Else
        RetVal = 0
    End If
    pvArraySize = RetVal
End Function

Private Sub pvAppendLogText(txtLog As TextBox, sValue As String)
    Call SendMessage(txtLog.hWnd, WM_SETREDRAW, 0, ByVal 0)
    Call SendMessage(txtLog.hWnd, EM_SETSEL, 0, ByVal -1)
    Call SendMessage(txtLog.hWnd, EM_SETSEL, -1, ByVal -1)
    Call SendMessage(txtLog.hWnd, EM_REPLACESEL, 1, ByVal sValue)
    Call SendMessage(txtLog.hWnd, EM_SETSEL, 0, ByVal -1)
    Call SendMessage(txtLog.hWnd, EM_SETSEL, -1, ByVal -1)
    Call SendMessage(txtLog.hWnd, WM_SETREDRAW, 1, ByVal 0)
    Call SendMessage(txtLog.hWnd, WM_VSCROLL, SB_BOTTOM, ByVal 0)
End Sub