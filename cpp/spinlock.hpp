#pragma once

#include <atomic>

class RWSpinLock {
    std::atomic<int> reader_count{0};
    std::atomic_flag writer_lock = ATOMIC_FLAG_INIT;

public:
    // 共有ロック（リーダー用）
    void lock_shared() {
        while (true) {
            while (writer_lock.test(std::memory_order_relaxed)) {
                // ライターがいるので待機
            }
            reader_count.fetch_add(1, std::memory_order_acquire);
            if (!writer_lock.test(std::memory_order_relaxed))
                break;
            reader_count.fetch_sub(1, std::memory_order_release);
        }
    }

    bool try_lock_shared() {
        if (writer_lock.test(std::memory_order_relaxed)) {
            return false; // ライターがいる
        }
        reader_count.fetch_add(1, std::memory_order_acquire);
        if (writer_lock.test(std::memory_order_relaxed)) {
            reader_count.fetch_sub(1, std::memory_order_release);
            return false;
        }
        return true;
    }

    void unlock_shared() {
        reader_count.fetch_sub(1, std::memory_order_release);
    }

    // 排他ロック（ライター用）
    void lock() {
        while (writer_lock.test_and_set(std::memory_order_acquire)) {
            // 他のライターがいるので待機
        }
        while (reader_count.load(std::memory_order_acquire) > 0) {
            // リーダーが残っている間は待つ
        }
    }

    bool try_lock() {
        if (writer_lock.test_and_set(std::memory_order_acquire)) {
            return false; // 他のライターがいる
        }
        if (reader_count.load(std::memory_order_acquire) > 0) {
            writer_lock.clear(std::memory_order_release);
            return false; // 読者がいる
        }
        return true;
    }

    void unlock() {
        writer_lock.clear(std::memory_order_release);
    }
};
