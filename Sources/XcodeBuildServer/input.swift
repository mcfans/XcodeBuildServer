import Foundation
import Dispatch

/// BSP 消息处理回调类型
typealias BSPMessageHandler = (Data) -> Void

/// 一个用于从标准输入读取BSP数据的类，使用DispatchIO
class BSPInputReader {
    private let stdInFd: Int32
    private var io: DispatchIO?
    private var headerBuffer = Data()
    private var messageBuffer = Data()
    private var expectedLength: Int = 0
    private var isReadingHeader = true
    private let queue = DispatchQueue(label: "com.bsp.reader")
    private let messageHandler: BSPMessageHandler
    
    init(messageHandler: @escaping BSPMessageHandler) {
        // 获取标准输入的文件描述符
        self.stdInFd = FileHandle.standardInput.fileDescriptor
        self.messageHandler = messageHandler
    }
    
    /// 开始读取BSP消息
    func start() {
        // 创建DispatchIO对象处理标准输入
        io = DispatchIO(type: .stream, fileDescriptor: stdInFd, queue: queue) { [weak self] error in
            if error != 0 {
                print("DispatchIO错误：\(error)", to: &StandardError.shared)
            }
            self?.cleanup()
        }
        
        // 设置读取低水位，1表示有任何数据就触发读取
        io?.setLimit(lowWater: 1)
        
        // 开始读取操作
        readNext()
    }
    
    /// 读取数据
    private func readNext() {
        guard let io = io else { return }
        
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self = self else { return }
            
            if error != 0 {
                print("读取错误：\(error)", to: &StandardError.shared)
                if done {
                    self.cleanup()
                }
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if done {
                    self.cleanup()
                }
                return
            }
            
            // 处理读取到的数据
            self.processData(data)
            
            // 如果未结束，继续读取
            if !done {
                self.readNext()
            } else {
                self.cleanup()
            }
        }
    }
    
    /// 处理读取到的数据
    private func processData(_ data: DispatchData) {
        let buffer = Data(data)
        
        if isReadingHeader {
            // 处理头部数据
            headerBuffer.append(buffer)
            processHeaderBuffer()
        } else {
            // 处理消息体数据
            messageBuffer.append(buffer)
            processMessageBuffer()
        }
    }
    
    /// 处理头部缓冲区
    private func processHeaderBuffer() {
        // 寻找头部结束标记 (两个连续的CRLF: \r\n\r\n)
        if let range = headerBuffer.range(of: Data([13, 10, 13, 10])) {
            // 提取头部数据
            let headerData = headerBuffer.prefix(range.upperBound)
            // 解析头部
            if let headerString = String(data: headerData, encoding: .utf8) {
                let headers = parseHeaders(headerString)
                
                // 获取Content-Length
                if let contentLengthStr = headers["Content-Length"],
                   let contentLength = Int(contentLengthStr) {
                    expectedLength = contentLength
                    
                    // 将剩余数据添加到消息缓冲区
                    let remainingData = headerBuffer.suffix(from: range.upperBound)
                    if !remainingData.isEmpty {
                        messageBuffer.append(remainingData)
                    }
                    
                    // 切换到读取消息体
                    isReadingHeader = false
                    headerBuffer.removeAll()
                    
                    // 检查消息体是否已接收完整
                    processMessageBuffer()
                } else {
                    print("无效的Content-Length头", to: &StandardError.shared)
                    // 重置状态，准备读取下一个消息头
                    headerBuffer.removeAll()
                }
            }
        }
    }
    
    /// 处理消息体缓冲区
    private func processMessageBuffer() {
        // 检查是否已接收到完整消息
        if messageBuffer.count >= expectedLength {
            // 提取完整消息
            let messageData = messageBuffer.prefix(expectedLength)
            
            // 直接传递原始消息数据给外部处理
            messageHandler(messageData)
            
            // 保留剩余数据用于下一条消息
            messageBuffer = messageBuffer.count > expectedLength
                ? messageBuffer.suffix(from: expectedLength)
                : Data()
            
            // 重置状态，准备读取下一个消息头
            isReadingHeader = true
            expectedLength = 0
            
            // 检查是否有完整的头部在缓冲区中
            if !messageBuffer.isEmpty {
                headerBuffer = messageBuffer
                messageBuffer = Data()
                processHeaderBuffer()
            }
        }
    }
    
    /// 解析头部字符串
    private func parseHeaders(_ headerString: String) -> [String: String] {
        var headers = [String: String]()
        
        let lines = headerString
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        return headers
    }
    
    /// 清理资源
    private func cleanup() {
        io?.close()
        io = nil
    }
}

/// 用于将输出重定向到标准错误的辅助类
struct StandardError: TextOutputStream {
    nonisolated(unsafe) static var shared = StandardError()
    
    func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

