#pragma once

#include<future>
#include<mutex>
#include<vector>
#include<algorithm>
#include<thread>
#include<functional>
#include<chrono>


class AsyncTaskPool {
  public:
    // 非同期タスクを登録
    void enqueue(std::function<void()>&& func) {
        std::lock_guard<std::mutex> lock(mutex_);
        tasks_.emplace_back(std::async(std::launch::async, std::move(func)));
    }

    // 完了したタスクを監視リストから削除
    void removeDone() {
        std::lock_guard<std::mutex> lock(mutex_);
        tasks_.erase(
            std::remove_if(tasks_.begin(), tasks_.end(),
                [](std::future<void>& fut) {
                    return fut.wait_for(std::chrono::seconds(0)) == std::future_status::ready;
                }),
            tasks_.end()
        );
    }

    // 現在監視中のタスク数
    size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return tasks_.size();
    }

  private:
    mutable std::mutex mutex_;
    std::vector<std::future<void>> tasks_;
};
